#!/usr/bin/env python3
"""Backfill every local agent chat into Wolf Leader.

Reads Cursor transcripts (~/.cursor/projects/*/agent-transcripts/**/*.jsonl) and
Claude Code sessions (~/.claude/projects/*/*.jsonl), works out which project each
belongs to, creates missing projects, and saves each chat through the hub's normal
save pipeline (memories, embeddings, brief, vault note, wiki). Idempotent: re-running
updates the same chats by session_id.

Usage:
  python wolf-backfill.py --since 2026-09-02 [--map groups.json] [--dry-run] [--api URL]

groups.json (optional) merges several workspace folders into one project and names it:
  {
    "groups": [
      {"slug": "media-tools", "name": "Media Tools",
       "path": "C:\\Users\\me\\Projects\\MediaTools",
       "workspaces": ["c-Users-me-Projects-MediaTools", "c-Users-me-Projects-MediaToolsScratch"]}
    ],
    "loose": {"1789504456611": {"slug": "gpu-tuning", "name": "GPU Tuning"}}
  }
Anything not listed becomes its own project named after its folder.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

MAX_MSG_CHARS = 12000


# ----------------------------------------------------------------- hub client
def load_api(override: str | None) -> str:
    if override:
        return override.rstrip("/")
    api = os.environ.get("WOLF_LEADER_API_LOCAL") or os.environ.get("WOLF_LEADER_API")
    env_file = Path.home() / ".cursor" / "wolf-leader.env"
    if not api and env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            if line.startswith("WOLF_LEADER_API="):
                api = line.split("=", 1)[1].strip()
    return (api or "http://wolf.local:6971").rstrip("/")


def api_json(method: str, url: str, payload: dict | None = None, *, timeout: int = 600) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


# ------------------------------------------------------------ transcript parse
def _text_of(content) -> str:
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text").strip()
    return ""


def _clean(text: str) -> str:
    # Prefer the actual typed query when Cursor wrapped it with injected context.
    m = re.search(r"<user_query>(.*?)</user_query>", text, flags=re.S)
    if m and m.group(1).strip():
        text = m.group(1)
    text = re.sub(r"<timestamp>.*?</timestamp>\s*", "", text, flags=re.S)
    text = re.sub(r"<external_links>.*?</external_links>\s*", "", text, flags=re.S)
    text = re.sub(r"<system_reminder>.*?</system_reminder>", "", text, flags=re.S)
    text = re.sub(r"</?user_query>", "", text)
    return text.strip()


def _truncate(text: str) -> str:
    return text if len(text) <= MAX_MSG_CHARS else text[: MAX_MSG_CHARS - 60] + "\n\n[... truncated ...]"


def parse_jsonl(path: Path) -> tuple[list[dict], str | None]:
    """Cursor or Claude Code transcript -> ([{role, content}], workspace_path or None)."""
    messages: list[dict] = []
    pending: list[str] = []
    workspace: str | None = None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        # Claude Code carries cwd on every entry.
        if not workspace and isinstance(e.get("cwd"), str):
            workspace = e["cwd"]
        role = e.get("role") or e.get("type")
        msg = e.get("message") if isinstance(e.get("message"), dict) else e
        content = msg.get("content")
        # Cursor agents call resolve_project with the workspace; harvest it.
        if not workspace and isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    inp = b.get("input")
                    args = inp.get("arguments") if isinstance(inp, dict) else None
                    p = args.get("path") if isinstance(args, dict) else None
                    if isinstance(p, str) and re.match(r"^[A-Za-z]:\\|^/", p):
                        workspace = p
                        break
        text = _text_of(content)
        if not text:
            continue
        if role == "user":
            if pending:
                messages.append({"role": "assistant", "content": _truncate("\n\n".join(pending))})
                pending = []
            cleaned = _clean(text)
            if cleaned:
                messages.append({"role": "user", "content": _truncate(cleaned)})
        elif role == "assistant":
            pending.append(text)
    if pending:
        messages.append({"role": "assistant", "content": _truncate("\n\n".join(pending))})
    return messages, workspace


def title_from(messages: list[dict]) -> str:
    for m in messages:
        if m["role"] == "user":
            t = re.sub(r"\s+", " ", m["content"]).strip()
            if t:
                return (t[:77] + "...") if len(t) > 80 else t
    return "Untitled session"


# ------------------------------------------------------------- discovery
def cursor_sessions(since: datetime) -> list[dict]:
    root = Path.home() / ".cursor" / "projects"
    out = []
    if not root.is_dir():
        return out
    for ws in root.iterdir():
        tdir = ws / "agent-transcripts"
        if not tdir.is_dir():
            continue
        for f in tdir.rglob("*.jsonl"):
            mtime = datetime.fromtimestamp(f.stat().st_mtime, timezone.utc)
            if mtime < since:
                continue
            out.append({"source": "cursor", "workspace_key": ws.name, "session_id": f.stem, "path": f, "mtime": mtime})
    return out


def claude_sessions(since: datetime) -> list[dict]:
    root = Path.home() / ".claude" / "projects"
    out = []
    if not root.is_dir():
        return out
    for ws in root.iterdir():
        if not ws.is_dir():
            continue
        for f in ws.glob("*.jsonl"):
            mtime = datetime.fromtimestamp(f.stat().st_mtime, timezone.utc)
            if mtime < since:
                continue
            out.append({"source": "claude", "workspace_key": ws.name, "session_id": f.stem, "path": f, "mtime": mtime})
    return out


def guess_path_from_key(key: str) -> str | None:
    """`c-Users-me-Documents-Projects-Foo` -> `C:\\Users\\me\\Documents\\Projects\\Foo` (best effort)."""
    m = re.match(r"^([a-z])-(.+)$", key)
    if m and sys.platform.startswith("win"):
        return f"{m.group(1).upper()}:\\" + m.group(2).replace("-", "\\")
    if key.startswith("-"):
        return "/" + key.strip("-").replace("-", "/")
    return None


# ------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="2026-01-01", help="YYYY-MM-DD; only transcripts modified on/after")
    ap.add_argument("--map", default=None, help="groups.json (see module docstring)")
    ap.add_argument("--api", default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--min-messages", type=int, default=2)
    args = ap.parse_args()

    api = load_api(args.api)
    since = datetime.strptime(args.since, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    device = socket.gethostname()

    groups_by_ws: dict[str, dict] = {}
    loose: dict[str, dict] = {}
    if args.map:
        cfg = json.loads(Path(args.map).read_text(encoding="utf-8"))
        for g in cfg.get("groups", []):
            for ws in g.get("workspaces", []):
                groups_by_ws[ws] = g
        loose = cfg.get("loose", {})

    sessions = cursor_sessions(since) + claude_sessions(since)
    sessions.sort(key=lambda s: s["mtime"])
    print(f"hub: {api}\nfound {len(sessions)} transcript(s) since {args.since}\n")

    ensured: dict[str, dict] = {}  # slug -> project

    def ensure(slug: str | None, name: str | None, path: str) -> dict | None:
        key = slug or path
        if key in ensured:
            return ensured[key]
        if args.dry_run:
            ensured[key] = {"slug": slug or Path(path).name.lower(), "name": name or Path(path).name, "project_id": 0, "created": "?"}
            return ensured[key]
        try:
            p = api_json("POST", f"{api}/api/projects/ensure",
                         {"path": path, "slug": slug, "name": name, "device_name": device,
                          "description": f"Backfilled from {device}"})
        except urllib.error.HTTPError as exc:
            print(f"  !! ensure project failed for {path}: {exc.read().decode('utf-8', 'replace')[:200]}")
            return None
        ensured[key] = p
        print(f"  {'created' if p.get('created') else 'found  '} project {p['slug']} (#{p['project_id']})")
        return p

    saved = skipped = failed = 0
    for s in sessions:
        messages, ws_path = parse_jsonl(s["path"])
        if len(messages) < args.min_messages:
            skipped += 1
            continue
        g = groups_by_ws.get(s["workspace_key"])
        lo = loose.get(s["workspace_key"])
        if g:
            slug, name, ppath = g["slug"], g.get("name"), g.get("path") or ws_path
        elif lo:
            slug, name, ppath = lo["slug"], lo.get("name"), lo.get("path") or ws_path or f"loose/{s['workspace_key']}"
        else:
            ppath = ws_path or guess_path_from_key(s["workspace_key"]) or f"loose/{s['workspace_key']}"
            slug, name = None, None
        if not ppath:
            print(f"  ?? no path for {s['workspace_key']}/{s['session_id'][:8]}; skipped")
            skipped += 1
            continue

        proj = ensure(slug, name, ppath)
        if not proj:
            failed += 1
            continue
        # Register this transcript's own folder too when it differs from the group root.
        if ws_path and g and not args.dry_run and ws_path.rstrip("\\/") != str(ppath).rstrip("\\/"):
            try:
                api_json("POST", f"{api}/api/projects/{proj['project_id']}/paths",
                         {"path": ws_path, "kind": "workspace", "device_name": device})
            except urllib.error.HTTPError:
                pass

        title = title_from(messages)
        occurred = s["mtime"].replace(tzinfo=None).isoformat()
        print(f"  [{s['source']}] {s['mtime']:%m/%d %H:%M} -> {proj['slug']}: {title[:60]} ({len(messages)} msgs)")
        if args.dry_run:
            saved += 1
            continue
        try:
            api_json("POST", f"{api}/api/save-project", {
                "session_id": s["session_id"], "slug": proj["slug"], "workspace_path": ws_path or ppath,
                "title": title, "messages": messages, "occurred_at": occurred,
            })
            saved += 1
        except urllib.error.HTTPError as exc:
            failed += 1
            print(f"     !! save failed: {exc.read().decode('utf-8', 'replace')[:200]}")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"     !! save failed: {exc}")

    print(f"\nsaved {saved}, skipped {skipped} (too short), failed {failed}; projects touched: {len(ensured)}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
