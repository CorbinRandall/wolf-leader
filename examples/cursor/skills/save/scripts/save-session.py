#!/usr/bin/env python3
"""Save current Cursor session to Wolf Leader when hub is remote (no shared transcript mount)."""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

MAX_MSG_CHARS = 12000
DEFAULT_ROOT = Path.home() / ".cursor" / "projects"


def load_env() -> tuple[str, Path | None]:
    api = os.environ.get("WOLF_LEADER_API_LOCAL") or os.environ.get("WOLF_LEADER_API") or "http://127.0.0.1:6971"
    env_file = Path.home() / ".cursor" / "wolf-leader.env"
    if env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key, value = key.strip(), value.strip()
            if key == "WOLF_LEADER_API_LOCAL" and value:
                api = value
            elif key == "WOLF_LEADER_API" and value and not os.environ.get("WOLF_LEADER_API_LOCAL"):
                api = value
    custom = os.environ.get("CURSOR_TRANSCRIPTS_ROOT")
    root = Path(custom) if custom else None
    return api.rstrip("/"), root


def extract_text(entry: dict) -> str:
    parts = []
    for block in entry.get("message", {}).get("content", []):
        if block.get("type") == "text" and block.get("text"):
            parts.append(block["text"])
    return "\n".join(parts).strip()


def clean_user(text: str) -> str:
    return re.sub(r"</?user_query>", "", text).strip()


def truncate(text: str, limit: int = MAX_MSG_CHARS) -> str:
    if len(text) <= limit:
        return text
    return text[: limit - 80] + "\n\n[... truncated for storage ...]"


def parse_transcript(path: Path) -> list[dict[str, str]]:
    messages: list[dict[str, str]] = []
    pending_assistant: list[str] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        role = entry.get("role")
        text = extract_text(entry)
        if not text:
            continue
        if role == "user":
            if pending_assistant:
                messages.append({
                    "role": "assistant",
                    "content": truncate("\n\n".join(pending_assistant)),
                })
                pending_assistant = []
            messages.append({"role": "user", "content": truncate(clean_user(text))})
        elif role == "assistant":
            pending_assistant.append(text)
    if pending_assistant:
        messages.append({
            "role": "assistant",
            "content": truncate("\n\n".join(pending_assistant)),
        })
    return messages


def find_transcript(
    session_id: str | None = None,
    *,
    root_hint: Path | None = None,
) -> tuple[str, Path] | tuple[None, None]:
    sid = (session_id or os.environ.get("CURSOR_SESSION_ID") or "").strip()
    roots: list[Path] = []
    if root_hint:
        roots.append(root_hint)
    roots.append(DEFAULT_ROOT / "root" / "agent-transcripts")
    if DEFAULT_ROOT.is_dir():
        for child in sorted(DEFAULT_ROOT.iterdir()):
            candidate = child / "agent-transcripts"
            if candidate.is_dir():
                roots.append(candidate)

    seen: set[Path] = set()
    for root in roots:
        if root in seen or not root.is_dir():
            continue
        seen.add(root)
        if sid:
            path = root / sid / f"{sid}.jsonl"
            if path.is_file():
                return sid, path
        candidates: list[tuple[float, str, Path]] = []
        for child in root.iterdir():
            if not child.is_dir() or child.name == "subagents":
                continue
            path = child / f"{child.name}.jsonl"
            if path.is_file():
                candidates.append((path.stat().st_mtime, child.name, path))
        if candidates:
            candidates.sort(reverse=True)
            _, found_sid, path = candidates[0]
            return found_sid, path
    return None, None


def title_from_messages(messages: list[dict[str, str]]) -> str:
    for msg in messages:
        if msg.get("role") != "user":
            continue
        text = clean_user(msg.get("content") or "")
        text = re.sub(r"\s+", " ", text).strip()
        if len(text) > 80:
            text = text[:77] + "..."
        if text:
            return text
    return "Cursor session"


def post_save(api: str, payload: dict) -> dict:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"{api}/api/save-project",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main() -> int:
    slug = sys.argv[1] if len(sys.argv) > 1 else None
    session_id = os.environ.get("CURSOR_SESSION_ID")
    api, root_hint = load_env()

    # Path A: hub has local transcript mount (same host as Cursor SSH)
    try:
        body: dict = {}
        if slug:
            body["slug"] = slug
        if session_id:
            body["session_id"] = session_id
        result = post_save(api, body)
        print(json.dumps(result, indent=2))
        return 0 if result.get("ok") else 1
    except urllib.error.HTTPError as exc:
        if exc.code != 400:
            print(exc.read().decode("utf-8", errors="replace"), file=sys.stderr)
            return 1
        detail = exc.read().decode("utf-8", errors="replace")
        if "No Cursor transcript" not in detail and "transcript" not in detail.lower():
            print(detail, file=sys.stderr)
            return 1

    # Path B: read local transcript and upload messages
    sid, path = find_transcript(session_id, root_hint=root_hint)
    if not path:
        print("No local Cursor transcript found under ~/.cursor/projects", file=sys.stderr)
        return 1

    messages = parse_transcript(path)
    if not messages:
        print(f"Transcript empty: {path}", file=sys.stderr)
        return 1

    payload = {
        "title": title_from_messages(messages),
        "content": f"Synced from local transcript {sid}",
        "messages": messages,
        "session_id": sid,
        "workspace_path": os.environ.get("CURSOR_WORKSPACE") or str(Path.cwd()),
    }
    if slug:
        payload["slug"] = slug

    try:
        result = post_save(api, payload)
        print(json.dumps(result, indent=2))
        return 0 if result.get("ok") else 1
    except urllib.error.HTTPError as exc:
        print(exc.read().decode("utf-8", errors="replace"), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
