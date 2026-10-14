#!/usr/bin/env python3
"""Bring what your AI tools already know into Wolf Leader.

    wolf-import.py scan [--api URL]                 find past sessions, profile notes and skills (JSON out)
    wolf-import.py import PLAN.json [--api URL]     save the chosen sessions and profile notes (JSON lines out)

`scan` changes nothing. It reads, on this computer:

- sessions from Claude Code (~/.claude/projects), Codex (~/.codex/sessions) and Cursor
  (~/.cursor/projects/.../agent-transcripts), grouped by the folder they were run in, each
  group with a suggested project: the one that already owns the folder, the closest match by
  content, or a new one named after the folder
- notes those tools keep about you (Claude memory files of type user / feedback,
  ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md), split into profile items
- the skills each tool has installed

`import` takes the scan with the person's choices filled in and saves each session through the
hub's normal save, so memories, briefs and search work as if an agent had saved it. Sessions the
hub already has are skipped, so running it twice is safe.

Standard library only.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
HERE = Path(__file__).resolve().parent
SESSION_PY = HERE.parent / "examples" / "shared" / "skills" / "wolfhowl" / "scripts" / "session.py"
SKIP_PREFIXES = ("<environment_context>", "<recommended_plugins>", "# AGENTS.md instructions", "<system-reminder>",
                 "<skills_instructions>", "<codex_apps_client_time_context>", "<heartbeat>", "<command-")
MIN_BYTES = 1500


def load_session_helpers():
    spec = importlib.util.spec_from_file_location("wl_session", SESSION_PY)
    if not spec or not spec.loader:
        raise SystemExit(f"session parser missing: {SESSION_PY}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def api_url(arg: str | None) -> str:
    if arg:
        return arg.rstrip("/")
    for env in (HOME / ".claude" / "wolf-leader.env", HOME / ".codex" / "wolf-leader.env", HOME / ".cursor" / "wolf-leader.env"):
        if env.is_file():
            for line in env.read_text(encoding="utf-8", errors="replace").splitlines():
                key, _, value = line.strip().partition("=")
                if key in ("WOLF_LEADER_API_LOCAL", "WOLF_LEADER_API") and value:
                    return value.strip().strip('"').rstrip("/")
    return os.environ.get("WOLF_LEADER_API", "http://127.0.0.1:6971").rstrip("/")


def call(api: str, method: str, path: str, payload=None, timeout: int = 120):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(api + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode() or "null")


def iso(ts: float | None) -> str | None:
    return datetime.fromtimestamp(ts, timezone.utc).replace(tzinfo=None).isoformat() if ts else None


def first_user_text(path: Path, limit_lines: int = 400) -> tuple[str, str | None, str | None]:
    """(first thing the person said, folder it ran in, when it started), reading only the start."""
    text, folder, started = "", None, None
    with path.open(encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh):
            if i > limit_lines:
                break
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(row, dict):
                continue
            payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
            folder = folder or row.get("cwd") or payload.get("cwd")
            started = started or row.get("timestamp") or payload.get("timestamp")
            if text:
                continue
            item = payload if row.get("type") == "response_item" else row
            message = item.get("message") if isinstance(item.get("message"), dict) else {}
            role = item.get("role") or message.get("role")
            if role != "user" or row.get("isMeta"):
                continue
            content = message.get("content", item.get("content"))
            if isinstance(content, list):
                content = " ".join(b.get("text", "") for b in content if isinstance(b, dict))
            content = re.sub(r"</?user_query>", "", str(content or "")).strip()
            if content and not content.startswith(SKIP_PREFIXES):
                text = " ".join(content.split())
    return text, folder, started


def cursor_folder(project_dir: str) -> str | None:
    """Cursor names a project's folder by joining the path with dashes; rebuild it from what exists."""
    if project_dir.isdigit() or project_dir.startswith("var-folders"):
        return None
    parts, path = project_dir.split("-"), "/"
    i = 0
    while i < len(parts):
        # Take the longest run of parts that names a folder that exists (names can contain dashes).
        for j in range(len(parts), i, -1):
            candidate = os.path.join(path, "-".join(parts[i:j]))
            if os.path.isdir(candidate):
                path, i = candidate, j
                break
        else:
            return None
    return path if path != "/" else None


def find_sessions() -> list[dict]:
    out: list[dict] = []
    codex_names: dict[str, str] = {}
    index = HOME / ".codex" / "session_index.jsonl"
    if index.is_file():
        for line in index.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                row = json.loads(line)
                codex_names[row["id"]] = row.get("thread_name") or ""
            except (json.JSONDecodeError, KeyError):
                continue
    for root in (HOME / ".codex" / "sessions", HOME / ".codex" / "archived_sessions"):
        if not root.is_dir():
            continue
        for path in root.rglob("rollout-*.jsonl"):
            match = re.search(r"([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})", path.name)
            if not match:
                continue
            sid = match.group(1)
            out.append({"tool": "codex", "id": sid, "path": str(path), "name_hint": codex_names.get(sid, "")})
    claude = HOME / ".claude" / "projects"
    if claude.is_dir():
        for path in claude.glob("*/*.jsonl"):
            out.append({"tool": "claude", "id": path.stem, "path": str(path)})
    cursor = HOME / ".cursor" / "projects"
    if cursor.is_dir():
        for path in cursor.glob("*/agent-transcripts/*/*.jsonl"):
            out.append({"tool": "cursor", "id": path.stem, "path": str(path),
                        "folder_hint": cursor_folder(path.parts[-4])})
    # A resumed Codex thread writes another file with the same id: keep the newest one.
    newest: dict[tuple[str, str], dict] = {}
    for s in out:
        key = (s["tool"], s["id"])
        if key not in newest or os.path.getmtime(s["path"]) > os.path.getmtime(newest[key]["path"]):
            newest[key] = s
    return list(newest.values())


def is_broad(folder: str | None) -> bool:
    if not folder:
        return True
    n = folder.rstrip("/").lower()
    return n in ("", "/", "/root", "/tmp") or bool(re.fullmatch(r"/(users|home)/[^/]+", n)) or "/var/folders/" in n \
        or n.startswith("/private/var/") or "/documents/codex/20" in n  # Codex's dated scratch folders


def scan(api: str) -> dict:
    sessions = []
    for s in find_sessions():
        path = Path(s["path"])
        try:
            size = path.stat().st_size
        except OSError:
            continue
        if size < MIN_BYTES:
            continue
        said, folder, started = first_user_text(path)
        if not said:
            continue
        folder = folder or s.get("folder_hint")
        title = s.get("name_hint") or said[:90] + ("…" if len(said) > 90 else "")
        sessions.append({**s, "title": title, "said": said[:400], "folder": folder, "started": started,
                         "ended": iso(path.stat().st_mtime), "size": size})
    known = set(call(api, "POST", "/api/sessions/known", {"ids": [s["id"] for s in sessions]}).get("known", []))
    for s in sessions:
        s["already_in"] = s["id"] in known

    projects = {p["id"]: p["name"] for p in call(api, "GET", "/api/projects?limit=1000").get("projects", [])}
    groups: dict[str, dict] = {}

    def suggest_by_content(text: str) -> dict:
        try:
            best = call(api, "POST", "/api/projects/match", {"text": text[:20000]}).get("best") or {}
        except Exception:  # noqa: BLE001
            best = {}
        if best.get("project_id") and best.get("confidence") in ("high", "medium"):
            return {"action": "existing", "project_id": best["project_id"], "project_name": projects.get(best["project_id"], "")}
        return {}

    for s in sessions:
        if not is_broad(s["folder"]):
            key = s["folder"].rstrip("/")
            group = groups.setdefault(key, {"key": key, "folder": key, "label": os.path.basename(key) or key, "sessions": []})
            group["sessions"].append(s)
            continue
        # No project folder: decide session by session from what was said.
        suggestion = suggest_by_content(f"{s['title']}\n{s['said']}")
        if suggestion:
            key = f"project:{suggestion['project_id']}"
            group = groups.setdefault(key, {"key": key, "folder": None, "label": suggestion["project_name"],
                                            "suggestion": suggestion, "sessions": []})
        else:
            key = "loose"
            group = groups.setdefault(key, {"key": key, "folder": None, "label": "No clear project",
                                            "suggestion": {"action": "loose"}, "sessions": []})
        group["sessions"].append(s)

    for group in groups.values():
        if "suggestion" not in group:
            owner = None
            try:
                owner = call(api, "GET", "/api/paths/resolve?path=" + urllib.parse.quote(group["folder"])).get("project_id")
            except Exception:  # noqa: BLE001
                owner = None
            if owner:
                group["suggestion"] = {"action": "existing", "project_id": owner, "project_name": projects.get(owner, "")}
            else:
                text = "\n".join(f"{s['title']}\n{s['said']}" for s in group["sessions"][:12])
                group["suggestion"] = suggest_by_content(text) or {
                    "action": "new", "name": re.sub(r"[-_]+", " ", group["label"]).strip().title() or "New project"}
        times = sorted(t for s in group["sessions"] for t in (s.get("started"), s.get("ended")) if t)
        group.update({
            "first": times[0] if times else None, "last": times[-1] if times else None,
            "count": len(group["sessions"]), "new": sum(1 for s in group["sessions"] if not s["already_in"]),
            "tools": sorted({s["tool"] for s in group["sessions"]}),
        })
        group["sessions"].sort(key=lambda s: s.get("started") or s.get("ended") or "")

    tools = {}
    for s in sessions:
        t = tools.setdefault(s["tool"], {"tool": s["tool"], "sessions": 0, "new": 0})
        t["sessions"] += 1
        t["new"] += 0 if s["already_in"] else 1
    ordered = sorted(groups.values(), key=lambda g: (g["key"] == "loose", -g["new"], g["label"].lower()))
    return {"tools": sorted(tools.values(), key=lambda t: t["tool"]), "groups": ordered,
            "profile": profile_candidates(), "skills": local_skills()}


def profile_candidates() -> list[dict]:
    sys.path.insert(0, str(HERE.parent))
    try:
        from ide_storage.profiles import items_from_text  # type: ignore
    except Exception:  # noqa: BLE001  - the app bundle has the hub sources; a bare checkout too
        def items_from_text(text, source, default_kind="about"):  # type: ignore
            return [{"text": " ".join(line.split()), "kind": default_kind, "source": source}
                    for line in text.splitlines() if 12 <= len(line.strip()) <= 600 and line.strip()[0] in "-*"]
    found: list[dict] = []

    def add(path: Path, source: str, kind: str = "about") -> None:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return
        for item in items_from_text(text, source, kind):
            found.append({**item, "file": str(path)})

    for path in (HOME / ".claude" / "projects").glob("*/memory/*.md"):
        if path.name == "MEMORY.md":
            continue
        head = path.read_text(encoding="utf-8", errors="replace")[:600]
        kind = re.search(r"type:\s*(\w+)", head)
        if kind and kind.group(1) in ("user", "feedback"):
            add(path, "claude", "about" if kind.group(1) == "user" else "preference")
    for path, source in ((HOME / ".claude" / "CLAUDE.md", "claude"), (HOME / ".codex" / "AGENTS.md", "codex")):
        if path.is_file():
            add(path, source, "preference")
    seen, unique = set(), []
    for item in found:
        key = item["text"].lower()
        if key not in seen:
            seen.add(key)
            unique.append(item)
    return unique


def local_skills() -> list[dict]:
    places = {"claude": HOME / ".claude" / "skills", "codex": HOME / ".agents" / "skills", "cursor": HOME / ".cursor" / "skills"}
    skills: dict[str, dict] = {}
    for tool, root in places.items():
        if not root.is_dir():
            continue
        for skill in sorted(root.iterdir()):
            if (skill / "SKILL.md").is_file():
                entry = skills.setdefault(skill.name, {"name": skill.name, "tools": [], "path": str(skill)})
                entry["tools"].append(tool)
    return sorted(skills.values(), key=lambda s: s["name"])


def run_import(api: str, plan: dict) -> int:
    helpers = load_session_helpers()
    projects = {p["id"]: p for p in call(api, "GET", "/api/projects?limit=1000").get("projects", [])}
    groups = [g for g in plan.get("groups", []) if (g.get("choice") or {}).get("action") not in (None, "skip")]
    todo = [(g, s) for g in groups for s in g.get("sessions", []) if not s.get("already_in")]
    total, done, failed = len(todo), 0, 0
    print(json.dumps({"event": "start", "total": total}), flush=True)
    slugs: dict[str, str | None] = {}
    for group in groups:
        choice = group["choice"]
        if choice["action"] == "existing":
            slugs[group["key"]] = (projects.get(choice["project_id"]) or {}).get("slug")
        elif choice["action"] == "new":
            # Worked on in the last month: in progress. Older: brought in as done, to keep Focus clear.
            recent = max((s.get("ended") or "" for s in group.get("sessions", [])), default="")
            cutoff = datetime.fromtimestamp(datetime.utcnow().timestamp() - 30 * 86400).isoformat()
            stale = not recent or recent < cutoff
            made = call(api, "POST", "/api/projects/start", {
                "name": choice.get("name") or group["label"], "folder": group.get("folder") or "",
                "description": f"Brought in from {', '.join(group.get('tools', []))} history.",
                "status": "in_progress" if not stale else "done",
            })
            slugs[group["key"]] = made.get("slug")
            print(json.dumps({"event": "project", "name": made.get("name"), "slug": made.get("slug")}), flush=True)
        else:
            slugs[group["key"]] = None
    for group, session in todo:
        path = Path(session["path"])
        try:
            messages = helpers.parse_transcript(path)
            if not messages:
                raise ValueError("no conversation in the file")
            body = {"session_id": session["id"], "title": session["title"], "messages": messages,
                    "occurred_at": (session.get("started") or session.get("ended") or "").replace("Z", ""),
                    "workspace_path": session.get("folder") or None}
            if slugs.get(group["key"]):
                body["slug"] = slugs[group["key"]]
            result = call(api, "POST", "/api/save-project", body, timeout=300)
            if not result.get("ok"):
                raise ValueError(result.get("error") or "not saved")
            done += 1
            event = {"event": "saved", "done": done + failed, "total": total, "title": session["title"][:80]}
        except Exception as exc:  # noqa: BLE001  - one bad file must not stop the rest
            failed += 1
            event = {"event": "failed", "done": done + failed, "total": total, "title": session["title"][:80], "why": str(exc)[:200]}
        print(json.dumps(event), flush=True)
    profile = plan.get("profile") or {}
    added = 0
    if profile.get("person") and profile.get("items"):
        added = call(api, "POST", f"/api/people/{urllib.parse.quote(profile['person'])}/profile/import",
                     {"items": profile["items"]}).get("added", 0)
    print(json.dumps({"event": "finished", "saved": done, "failed": failed, "profile_added": added}), flush=True)
    return 0 if not failed else 3


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["scan", "import"])
    ap.add_argument("plan", nargs="?")
    ap.add_argument("--api", default=None)
    args = ap.parse_args()
    api = api_url(args.api)
    if args.mode == "scan":
        print(json.dumps(scan(api)))
        return 0
    if not args.plan:
        ap.error("import needs the plan file")
    return run_import(api, json.loads(Path(args.plan).read_text(encoding="utf-8")))


if __name__ == "__main__":
    raise SystemExit(main())
