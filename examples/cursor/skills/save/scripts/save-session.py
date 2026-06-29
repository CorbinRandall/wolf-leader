#!/usr/bin/env python3
"""Save current Cursor session to Wolf Leader (existing project only)."""
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


def api_json(method: str, url: str, payload: dict | None = None, *, timeout: int = 120) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"} if data else {},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


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


def guess_project_id(api: str, text: str, slug: str | None) -> int | None:
    if slug:
        projects = api_json("GET", f"{api}/api/projects")
        for p in projects.get("projects") or []:
            if p.get("slug") == slug:
                return int(p["id"])
    lowered = text.lower()
    rules = [
        ("ide-storage", ("wolf leader", "ide-storage", "/save", "agent-brief")),
        ("docker-dashboard", ("docker-dashboard", "docker dashboard", "8888")),
        ("ssh-passwordless", ("ssh-passwordless", "authorized_keys")),
        ("s3-sleep", ("s3-sleep", "s3 sleep", "dynamix.s3.sleep")),
        ("nextcloud", ("nextcloud", "8081")),
    ]
    projects = api_json("GET", f"{api}/api/projects")
    slug_to_id = {p.get("slug"): p["id"] for p in projects.get("projects") or [] if p.get("slug")}
    for target_slug, needles in rules:
        if any(n in lowered for n in needles) and target_slug in slug_to_id:
            return int(slug_to_id[target_slug])
    return None


def save_via_hub_transcript(api: str, slug: str | None, session_id: str | None) -> dict | None:
    body: dict = {}
    if slug:
        body["slug"] = slug
    if session_id:
        body["session_id"] = session_id
    try:
        return api_json("POST", f"{api}/api/save-project", body)
    except urllib.error.HTTPError as exc:
        if exc.code != 400:
            raise
        detail = exc.read().decode("utf-8", errors="replace")
        if "No Cursor transcript" not in detail:
            raise
    return None


def save_via_remote_upload(
    api: str,
    *,
    slug: str | None,
    session_id: str | None,
    root_hint: Path | None,
) -> dict:
    sid, path = find_transcript(session_id, root_hint=root_hint)
    if not path:
        raise RuntimeError("No local Cursor transcript found under ~/.cursor/projects")

    messages = parse_transcript(path)
    if not messages:
        raise RuntimeError(f"Transcript empty: {path}")

    title = title_from_messages(messages)
    workspace = os.environ.get("CURSOR_WORKSPACE") or str(Path.cwd())
    text = "\n".join(m.get("content", "") for m in messages)

    created = api_json(
        "POST",
        f"{api}/api/chats",
        {
            "title": title,
            "workspace_path": workspace,
            "device_name": os.environ.get("WOLF_LEADER_DEVICE") or "cursor-client",
            "session_id": sid,
            "content": f"Synced {len(messages)} messages from local Cursor transcript",
            "messages": messages,
        },
    )
    chat_id = int(created["id"])
    project_id = guess_project_id(api, text, slug)
    if project_id is None:
        raise RuntimeError(
            "No existing project matched this conversation. Use /new to create a project and save."
        )
    api_json("PUT", f"{api}/api/chats/{chat_id}", {"project_id": project_id})
    distill = api_json("POST", f"{api}/api/projects/{project_id}/distill", {})
    api_json("PUT", f"{api}/api/chats/{chat_id}", {"status": "archived"})

    slug_out = (distill or {}).get("slug") or slug
    brief_url = f"{api}/api/projects/{slug_out}/agent-brief" if slug_out else None
    pickup = None
    if distill and isinstance(distill.get("spec"), dict):
        pickup = distill["spec"].get("pickup")

    return {
        "ok": True,
        "source": "remote_transcript_upload",
        "session_id": sid,
        "chat_id": chat_id,
        "project_id": project_id,
        "project_slug": slug_out,
        "project_name": (distill or {}).get("name"),
        "brief_url": brief_url,
        "pickup_prompt": pickup,
        "summary": (
            f"Saved to **{(distill or {}).get('name') or slug_out or 'hub'}** "
            f"from local transcript ({len(messages)} messages). Session archived."
        ),
    }


def main() -> int:
    slug = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else None
    session_id = os.environ.get("CURSOR_SESSION_ID")
    api, root_hint = load_env()

    try:
        result = save_via_hub_transcript(api, slug, session_id)
        if result is None:
            result = save_via_remote_upload(
                api, slug=slug, session_id=session_id, root_hint=root_hint
            )
        print(json.dumps(result, indent=2))
        return 0 if result.get("ok") else 1
    except urllib.error.HTTPError as exc:
        print(exc.read().decode("utf-8", errors="replace"), file=sys.stderr)
        return 1
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
