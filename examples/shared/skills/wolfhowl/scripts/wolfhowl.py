#!/usr/bin/env python3
"""/wolfhowl — save and broadcast the current session to Wolf Leader.

Usage:
  wolfhowl.py [SLUG] --session-id ID            save to a matched or named project
  wolfhowl.py SLUG --new --project-name "Name"  create the project, then save
  wolfhowl.py --git-only --howl-id N --commit "msg" [--git-init] [--push]

Everything mechanical happens here, not in the model: read this chat's local
transcript (Cursor, Codex, Claude Code), match it to an existing project, collect
git state (commit/branch/remote/dirty), and POST /api/howl. The hub extracts
memories, refreshes the brief, and archives the session. `summary` in the report
is what you read back to the user; `offers` is what you ask about.

Exit codes: 0 saved, 1 failed, 2 bad usage, 3 the user must choose a project.
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
SESSION_PY = HERE / "session.py"


def _load_session_helpers():
    """Load the bundled transcript parser without spending model tokens."""
    import importlib.util

    if not SESSION_PY.is_file():
        return None
    spec = importlib.util.spec_from_file_location("wl_howl_session", SESSION_PY)
    if not spec or not spec.loader:
        return None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_session = _load_session_helpers()
find_transcript = getattr(_session, "find_transcript", None)
parse_transcript = getattr(_session, "parse_transcript", None)
title_from_messages = getattr(_session, "title_from_messages", None)
session_id_from_env = getattr(_session, "session_id_from_env", lambda: os.environ.get("WOLF_LEADER_SESSION_ID") or "")


def load_env() -> tuple[str, Path | None]:
    if _session is not None:
        return _session.load_env()
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


def choose_project(
    api: str,
    workspace: str,
    text: str,
    messages: list[dict] | None,
    slug: str | None,
) -> tuple[str | None, dict]:
    """Pick the existing project this session belongs to, or None when unsure."""
    if slug:
        return slug, {}
    payload: dict = {"workspace_path": workspace, "text": text[:80_000]}
    if messages:
        payload["messages"] = [{"role": m["role"], "content": m["content"][:4000]} for m in messages[-60:]]
    try:
        match = api_json("POST", f"{api}/api/projects/match", payload, timeout=60)
    except Exception as exc:
        return None, {"error": str(exc)}
    best = match.get("best") or {}
    if best.get("slug") and best.get("confidence") in ("high", "medium"):
        return str(best["slug"]), match
    return None, match


def project_choices(api: str, match: dict) -> dict:
    """What the agent shows the user when no project matched confidently."""
    candidates = [
        {k: m.get(k) for k in ("slug", "name", "score", "confidence") if m.get(k) is not None}
        for m in (match.get("matches") or [])[:5]
    ]
    try:
        projects = api_json("GET", f"{api}/api/projects", timeout=30).get("projects") or []
    except Exception:
        projects = []
    return {
        "candidates": candidates,
        "projects": [{"slug": p.get("slug"), "name": p.get("name")} for p in projects][:60],
    }


def create_project(api: str, workspace: str, slug: str, name: str, description: str | None = None) -> dict:
    projects = api_json("GET", f"{api}/api/projects").get("projects") or []
    if any(project.get("slug") == slug for project in projects):
        raise RuntimeError(f"Project slug already exists: {slug}. Choose the existing project or a new slug.")
    return api_json("POST", f"{api}/api/projects", {
        "name": name,
        "slug": slug,
        "path": workspace,
        "description": description or f"Project created by /wolfhowl for {name}.",
        "metadata": {"semantic_descriptor": f"{name}. {description or ''} Created from workspace {Path(workspace).name}.".replace("  ", " ")},
    })


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


def git_followup(cwd: str, *, init: bool, message: str | None, push: bool) -> dict:
    """Run the git steps the user agreed to. Never forces, resets, or deletes."""
    done: list[str] = []

    def run(*cmd: str) -> None:
        r = subprocess.run(["git", "-C", cwd, *cmd], capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            raise RuntimeError(f"git {' '.join(cmd)}: {(r.stderr or r.stdout).strip()}")

    if _git(["rev-parse", "--is-inside-work-tree"], cwd) != "true":
        if not init:
            raise RuntimeError("not a git repo; pass --git-init after the user agrees to create one")
        run("init")
        done.append("git init")
    if message:
        if (_git(["status", "--porcelain"], cwd) or "").strip():
            run("add", "-A")
            run("commit", "-m", message)
            done.append(f"committed: {message}")
        else:
            done.append("nothing to commit")
    if push:
        if not _git(["remote", "get-url", "origin"], cwd):
            raise RuntimeError("no origin remote to push to; run /wolfhowl first so the hub can provide one")
        run("push", "-u", "origin", "HEAD")
        done.append("pushed to origin")
    return {"done": done, **git_state(cwd)}


def sync_share(workspace: str, slug: str | None) -> str | None:
    """Mirror the repo's files to the share so the hub can catalog them and /wolfeat can pull them."""
    try:
        from sync_share import push
        return push(workspace, slug)
    except Exception as exc:  # never block the howl on the mirror
        print(f"share mirror skipped: {exc}", file=sys.stderr)
        return None


def post_legacy_save(api: str, body: dict) -> int:
    """Older hubs have no /api/howl. Still save the session; git and catalog are skipped."""
    keys = ("session_id", "slug", "workspace_path", "title", "content", "messages", "occurred_at")
    try:
        report = api_json("POST", f"{api}/api/save-project", {k: body[k] for k in keys if body.get(k)})
    except urllib.error.HTTPError as exc:
        print(exc.read().decode("utf-8", errors="replace"), file=sys.stderr)
        return 1
    report["note"] = "This hub is older than /wolfhowl: the session was saved, but git state, file catalog, and offers need a hub update."
    print(json.dumps(report, indent=2))
    return 0 if report.get("ok") else 1


def post_howl(api: str, body: dict, workspace: str) -> int:
    try:
        report = api_json("POST", f"{api}/api/howl", body)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        if exc.code == 404 and "howl" not in detail.lower():
            return post_legacy_save(api, body)
        print(detail, file=sys.stderr)
        return 1
    except urllib.error.URLError as exc:
        print(f"wolfhowl: cannot reach Wolf Leader at {api}: {exc.reason}", file=sys.stderr)
        return 1
    wire_remote(report, workspace)
    print(json.dumps(report, indent=2))
    if report.get("needs_project_choice"):
        return 3
    return 0 if report.get("ok") else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Save and broadcast this session to Wolf Leader.")
    ap.add_argument("slug", nargs="?", default=None)
    ap.add_argument("--session-id", default=None, help="this chat's real session id")
    ap.add_argument("--title", default=None)
    ap.add_argument("--content", default=None, help="typed-line summary, when no local transcript can be read")
    ap.add_argument("--new", action="store_true", help="create a new project (only after the user chooses new)")
    ap.add_argument("--project-name", default=None, help="friendly name for a new project")
    ap.add_argument("--description", default=None, help="one-line description for a new project")
    ap.add_argument("--ingest", action="store_true", help="ingest cited file bodies now (only if the user already said yes)")
    ap.add_argument("--cite", action="append", default=[], help="file path this chat cited/changed (repeatable)")
    ap.add_argument("--no-catalog", action="store_true")
    ap.add_argument("--no-share", action="store_true", help="skip mirroring files to the share")
    ap.add_argument("--git-init", action="store_true", help="create a git repo here (only after the user agrees)")
    ap.add_argument("--commit", default=None, metavar="MESSAGE", help="commit all changes (only after the user agrees)")
    ap.add_argument("--push", action="store_true", help="push to origin (only after the user agrees)")
    ap.add_argument("--git-only", action="store_true", help="run the git steps and pin the SHA to --howl-id; do not save again")
    ap.add_argument("--howl-id", type=int, default=None)
    args = ap.parse_args()

    api, root_hint = load_env()
    workspace = os.environ.get("WOLF_LEADER_WORKSPACE") or os.environ.get("CURSOR_WORKSPACE") or str(Path.cwd())
    device = os.environ.get("WOLF_LEADER_DEVICE") or socket.gethostname()
    wants_git = bool(args.git_init or args.commit or args.push)

    # Git follow-up after an offer the user accepted: no second save, just pin the SHA.
    if args.git_only:
        if not wants_git:
            print("wolfhowl: --git-only needs --git-init, --commit, or --push", file=sys.stderr)
            return 2
        try:
            state = git_followup(workspace, init=args.git_init, message=args.commit, push=args.push)
        except Exception as exc:
            print(f"wolfhowl: {exc}", file=sys.stderr)
            return 1
        if args.howl_id and state.get("commit"):
            try:
                state["howl"] = api_json("PUT", f"{api}/api/howls/{args.howl_id}/git", {
                    "commit": state["commit"], "branch": state.get("branch"), "remote": state.get("remote"),
                }, timeout=60)
            except Exception as exc:
                state["howl_error"] = str(exc)
        print(json.dumps(state, indent=2))
        return 0

    session_id = args.session_id or session_id_from_env()
    # Never guess "newest transcript": that attached unrelated chats before.
    if not session_id:
        print("wolfhowl: pass --session-id <this chat's id>; refusing to guess which chat to save", file=sys.stderr)
        return 2

    # Read the transcript locally. This is the cheap path: no model tokens.
    messages: list[dict] = []
    transcript: Path | None = None
    if find_transcript and parse_transcript:
        _, transcript = find_transcript(session_id, root_hint=root_hint)
        if transcript:
            messages = parse_transcript(transcript)
    if not messages and not args.content:
        print(
            "wolfhowl: no local transcript found for this session. Re-run with "
            "--content \"decision: ...\\nactive_work: ...\" (a short typed-line summary).",
            file=sys.stderr,
        )
        return 2

    match_text = "\n".join(filter(None, [args.title, args.content]))
    chosen_slug, match = choose_project(api, workspace, match_text, messages, args.slug)
    if args.new:
        if not args.slug or not args.project_name:
            print("wolfhowl: --new requires SLUG and --project-name after the user confirms this is a new project", file=sys.stderr)
            return 2
        try:
            create_project(api, workspace, args.slug, args.project_name, args.description)
        except Exception as exc:
            print(f"wolfhowl: {exc}", file=sys.stderr)
            return 1
        chosen_slug = args.slug
    elif not chosen_slug:
        print(json.dumps({
            "ok": False,
            "needs_project_choice": True,
            "workspace_path": workspace,
            "message": "No confident existing project match. Ask whether this belongs to an existing project "
                       "or should become a new one, then re-run with the slug (add --new --project-name for a new one).",
            **({"match_error": match["error"]} if match.get("error") else {}),
            **project_choices(api, match),
        }, indent=2))
        return 3

    if wants_git:
        try:
            git_followup(workspace, init=args.git_init, message=args.commit, push=False)
        except Exception as exc:
            print(f"wolfhowl: {exc}", file=sys.stderr)
            return 1
    if not args.no_share:
        share = sync_share(workspace, chosen_slug)
        if share:
            print(f"mirrored files to {share}", file=sys.stderr)

    body: dict = {
        "slug": chosen_slug,
        "session_id": session_id,
        "workspace_path": workspace,
        "device_name": device,
        "git": git_state(workspace),
        "cited_paths": args.cite or None,
        "ingest_cited": bool(args.ingest),
        "refresh_catalog": not args.no_catalog,
        "client_os": client_os(),
    }
    if messages:
        body["messages"] = messages
        body["title"] = args.title or title_from_messages(messages)
        body["occurred_at"] = datetime.fromtimestamp(transcript.stat().st_mtime, timezone.utc).replace(tzinfo=None).isoformat()
        if args.content:
            body["content"] = args.content
    else:
        body["content"] = args.content
        body["title"] = args.title or "wolfhowl"

    code = post_howl(api, body, workspace)
    if code == 0 and args.push:
        # Push last: the hub may have just handed us an origin on the share.
        try:
            print(json.dumps({"git": git_followup(workspace, init=False, message=None, push=True)}, indent=2))
        except Exception as exc:
            print(f"wolfhowl: saved, but push failed: {exc}", file=sys.stderr)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
