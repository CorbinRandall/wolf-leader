#!/usr/bin/env python3
"""/wolfhowl — broadcast the current session to Wolf Leader.

Usage: wolfhowl.py [SLUG] [--ingest] [--cite PATH ...] [--no-catalog]

Collects: local git state (commit/branch/remote/dirty), hostname, workspace path,
and the Cursor transcript (or asks the hub to find it). POSTs /api/howl. Prints
the hub's report; `summary` is what you read back to the user, `offers` is what
you ask about.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
SAVE_SESSION_PY = HERE.parent.parent / "save" / "scripts" / "save-session.py"


def _load_save_helpers():
    """Reuse the /save skill's transcript parser (installed alongside)."""
    import importlib.util

    if not SAVE_SESSION_PY.is_file():
        return None
    spec = importlib.util.spec_from_file_location("wl_save_session", SAVE_SESSION_PY)
    if not spec or not spec.loader:
        return None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_save = _load_save_helpers()
find_transcript = getattr(_save, "find_transcript", None)
parse_transcript = getattr(_save, "parse_transcript", None)
title_from_messages = getattr(_save, "title_from_messages", None)


def load_env() -> tuple[str, Path | None]:
    if _save is not None:
        return _save.load_env()
    api = os.environ.get("WOLF_LEADER_API_LOCAL") or os.environ.get("WOLF_LEADER_API") or "http://wolf.local:6971"
    return api.rstrip("/"), None


def api_json(method: str, url: str, payload: dict | None = None, *, timeout: int = 600) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"} if data else {}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _git(args: list[str], cwd: str) -> str | None:
    try:
        r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=20)
    except Exception:
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def git_state(cwd: str) -> dict:
    inside = _git(["rev-parse", "--is-inside-work-tree"], cwd)
    if inside != "true":
        return {"is_repo": False}
    porcelain = _git(["status", "--porcelain"], cwd) or ""
    return {
        "is_repo": True,
        "commit": _git(["rev-parse", "HEAD"], cwd),
        "branch": _git(["rev-parse", "--abbrev-ref", "HEAD"], cwd),
        "remote": _git(["remote", "get-url", "origin"], cwd),
        "dirty_files": len([ln for ln in porcelain.splitlines() if ln.strip()]),
    }


def client_os() -> str:
    if sys.platform.startswith("win"):
        return "windows"
    if sys.platform == "darwin":
        return "mac"
    return "linux"


def wire_remote(report: dict, cwd: str) -> None:
    """The hub made a bare repo on the share for us; point `origin` at it.

    Only touches git config (no commit, no push); those stay in `offers`.
    """
    remote = report.get("git_remote") or {}
    target = remote.get("client") or remote.get("hub")
    git = report.get("git") or {}
    if not target or not git.get("is_repo") or remote.get("error"):
        return
    if _git(["remote", "get-url", "origin"], cwd):
        return
    r = subprocess.run(["git", "-C", cwd, "remote", "add", "origin", target], capture_output=True, text=True, timeout=20)
    if r.returncode == 0:
        report.setdefault("actions", []).append(f"set git origin -> {target}")
        git["remote"] = target
    else:
        report["git_remote"]["client_error"] = (r.stderr or r.stdout).strip()


def sync_share(workspace: str, slug: str | None) -> str | None:
    """Mirror the repo's files to the share so the hub can catalog them and /wolfeat can pull them."""
    try:
        from sync_share import push
        return push(workspace, slug)
    except Exception as exc:  # never block the howl on the mirror
        print(f"share mirror skipped: {exc}", file=sys.stderr)
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("slug", nargs="?", default=None)
    ap.add_argument("--ingest", action="store_true", help="ingest cited file bodies now (only if the user already said yes)")
    ap.add_argument("--cite", action="append", default=[], help="file path this chat cited/changed (repeatable)")
    ap.add_argument("--no-catalog", action="store_true")
    ap.add_argument("--title", default=None)
    ap.add_argument("--session-id", default=None, help="this chat's real session id (required outside Cursor)")
    ap.add_argument("--content", default=None, help="typed-line summary; used instead of a transcript (Claude Code)")
    ap.add_argument("--no-share", action="store_true", help="skip mirroring files to the share")
    args = ap.parse_args()

    api, root_hint = load_env()
    workspace = os.environ.get("CURSOR_WORKSPACE") or str(Path.cwd())
    device = os.environ.get("WOLF_LEADER_DEVICE") or socket.gethostname()
    session_id = args.session_id or os.environ.get("WOLF_LEADER_SESSION_ID") or os.environ.get("CURSOR_SESSION_ID")
    # Never guess "newest transcript": that attached unrelated chats before.
    if not session_id:
        print("wolfhowl: pass --session-id <this chat's id> (and --content for Claude Code); refusing to guess", file=sys.stderr)
        return 2
    if not args.no_share:
        share = sync_share(workspace, args.slug)
        if share:
            print(f"mirrored files to {share}", file=sys.stderr)

    body: dict = {
        "workspace_path": workspace,
        "device_name": device,
        "git": git_state(workspace),
        "cited_paths": args.cite or None,
        "ingest_cited": bool(args.ingest),
        "refresh_catalog": not args.no_catalog,
        "client_os": client_os(),
    }
    if args.slug:
        body["slug"] = args.slug
    if args.title:
        body["title"] = args.title

    body["session_id"] = session_id
    if args.content:
        # Agent-written summary (Claude Code etc.): no transcript lookup at all.
        body["content"] = args.content
        body.setdefault("title", "wolfhowl")
        try:
            report = api_json("POST", f"{api}/api/howl", body)
        except urllib.error.HTTPError as exc:
            print(exc.read().decode("utf-8", errors="replace"), file=sys.stderr)
            return 1
        wire_remote(report, workspace)
        print(json.dumps(report, indent=2))
        return 0 if report.get("ok") else 1
    # 1) Let the hub read the transcript if it can see it (hub on same machine).
    try:
        report = api_json("POST", f"{api}/api/howl", body)
        wire_remote(report, workspace)
        print(json.dumps(report, indent=2))
        return 0 if report.get("ok") else 1
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        if exc.code != 400 or "No Cursor transcript" not in detail:
            print(detail, file=sys.stderr)
            return 1

    # 2) Remote hub: upload the parsed local transcript.
    if not (find_transcript and parse_transcript):
        print("save skill scripts not found next to wolfhowl; install the client bundle again", file=sys.stderr)
        return 1
    sid, path = find_transcript(session_id, root_hint=root_hint)
    if sid != session_id:
        path = None  # only the exact chat, never a fallback
    if not path:
        print("No local Cursor transcript found under ~/.cursor/projects", file=sys.stderr)
        return 1
    messages = parse_transcript(path)
    if not messages:
        print(f"Transcript empty: {path}", file=sys.stderr)
        return 1
    body.update({
        "session_id": sid,
        "messages": messages,
        "title": args.title or title_from_messages(messages),
        "occurred_at": datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).replace(tzinfo=None).isoformat(),
    })
    try:
        report = api_json("POST", f"{api}/api/howl", body)
    except urllib.error.HTTPError as exc:
        print(exc.read().decode("utf-8", errors="replace"), file=sys.stderr)
        return 1
    wire_remote(report, workspace)
    print(json.dumps(report, indent=2))
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
