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
- account exports from Claude.ai and ChatGPT (the zip each site emails you), found in Downloads
  or passed with --export

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
SKILL_DIRS = {"claude": HOME / ".claude" / "skills", "codex": HOME / ".agents" / "skills", "cursor": HOME / ".cursor" / "skills"}
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


# --- Account exports (Claude.ai and ChatGPT) ---------------------------------------------------
# Chats on those websites never reach this computer on their own. Each site emails a zip on
# request (Claude: Settings > Privacy > Export data; ChatGPT: Settings > Data controls > Export).

_EXPORTS: dict[str, list[dict]] = {}


def _export_files(path: Path) -> list[tuple[str, bytes]]:
    """The conversations*.json files inside an export zip or unpacked folder."""
    import zipfile
    out = []
    if path.is_dir():
        for f in sorted(path.rglob("conversations*.json")):
            out.append((f.name, f.read_bytes()))
    elif path.suffix.lower() == ".zip":
        try:
            with zipfile.ZipFile(path) as archive:
                for name in archive.namelist():
                    if re.fullmatch(r"(?:.*/)?conversations(?:-\d+)?\.json", name):
                        out.append((name, archive.read(name)))
        except (zipfile.BadZipFile, OSError):
            return []
    return out


def find_exports(extra: list[str] | None = None) -> list[Path]:
    places = [Path(p).expanduser() for p in (extra or [])]
    downloads = HOME / "Downloads"
    if downloads.is_dir():
        for item in downloads.iterdir():
            if item.suffix.lower() == ".zip" and item.stat().st_size < 2_000_000_000:
                places.append(item)
            elif item.is_dir() and (any(item.glob("conversations*.json")) or any(item.glob("*/conversations*.json"))):
                places.append(item)
    found = []
    for place in places:
        if place.exists() and place not in found and _export_files(place):
            found.append(place)
    return found


def _when(value) -> str | None:
    if isinstance(value, (int, float)):
        return iso(float(value))
    if isinstance(value, str) and value:
        return value.replace("Z", "")[:26]
    return None


def _chatgpt_messages(conv: dict) -> list[dict]:
    """ChatGPT keeps each chat as a tree (edits make branches). Follow the branch that was kept."""
    mapping = conv.get("mapping") or {}
    node, path = conv.get("current_node"), []
    while node and node in mapping:
        path.append(mapping[node])
        node = mapping[node].get("parent")
    out = []
    for item in reversed(path):
        msg = item.get("message") or {}
        role = (msg.get("author") or {}).get("role")
        if role not in ("user", "assistant") or (msg.get("metadata") or {}).get("is_visually_hidden_from_conversation"):
            continue
        parts = (msg.get("content") or {}).get("parts") or []
        text = "\n".join(p for p in parts if isinstance(p, str)).strip()
        if text:
            out.append({"role": role, "content": text, "created_at": _when(msg.get("create_time"))})
    return out


def _claude_messages(conv: dict) -> list[dict]:
    out = []
    for msg in conv.get("chat_messages") or []:
        role = {"human": "user", "assistant": "assistant"}.get(msg.get("sender"))
        text = msg.get("text") or "\n".join(
            b.get("text", "") for b in msg.get("content") or [] if isinstance(b, dict) and b.get("type") == "text")
        if role and text.strip():
            out.append({"role": role, "content": text.strip(), "created_at": _when(msg.get("created_at"))})
    return out


def read_export(path: Path) -> list[dict]:
    """Every conversation in one export, as {id, tool, title, started, ended, messages}."""
    key = str(path)
    if key in _EXPORTS:
        return _EXPORTS[key]
    convs: list[dict] = []
    for _, raw in _export_files(path):
        try:
            data = json.loads(raw.decode("utf-8", errors="replace"))
        except json.JSONDecodeError:
            continue
        for conv in data if isinstance(data, list) else []:
            if not isinstance(conv, dict):
                continue
            if "mapping" in conv:
                tool, cid, messages = "chatgpt", conv.get("conversation_id") or conv.get("id"), _chatgpt_messages(conv)
                title, started, ended = conv.get("title"), _when(conv.get("create_time")), _when(conv.get("update_time"))
            elif "chat_messages" in conv:
                tool, cid, messages = "claude.ai", conv.get("uuid"), _claude_messages(conv)
                title, started, ended = conv.get("name"), _when(conv.get("created_at")), _when(conv.get("updated_at"))
            else:
                continue
            if cid and any(m["role"] == "user" for m in messages):
                convs.append({"id": f"{tool}-{cid}", "tool": tool, "title": (title or "").strip(),
                              "started": started, "ended": ended, "messages": messages})
    _EXPORTS[key] = convs
    return convs


def export_sessions(paths: list[Path]) -> list[dict]:
    out = []
    for path in paths:
        for conv in read_export(path):
            said = " ".join(next(m["content"] for m in conv["messages"] if m["role"] == "user").split())
            out.append({"tool": conv["tool"], "id": conv["id"], "path": str(path), "export": True,
                        "title": conv["title"] or said[:90], "said": said[:400], "folder": None,
                        "started": conv["started"], "ended": conv["ended"] or conv["started"],
                        "size": sum(len(m["content"]) for m in conv["messages"])})
    return out


def is_broad(folder: str | None) -> bool:
    if not folder:
        return True
    n = folder.rstrip("/").lower()
    return n in ("", "/", "/root", "/tmp") or bool(re.fullmatch(r"/(users|home)/[^/]+", n)) or "/var/folders/" in n \
        or n.startswith("/private/var/") or "/documents/codex/20" in n \
        or bool(re.fullmatch(r"/(users|home)/[^/]+/(downloads|desktop|documents|applications|projects)", n))


def scan(api: str, exports: list[str] | None = None) -> dict:
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
    export_paths = find_exports(exports)
    sessions += export_sessions(export_paths)
    known = set(call(api, "POST", "/api/sessions/known", {"ids": [s["id"] for s in sessions]}).get("known", []))
    for s in sessions:
        s["already_in"] = s["id"] in known

    rows = call(api, "GET", "/api/projects?limit=1000").get("projects", [])
    projects = {p["id"]: p["name"] for p in rows}
    # A person's own catch-all project ("Corbin") matches anything that mentions them; never suggest it.
    catch_all = {p["id"] for p in rows if "owner-folder" in str(p.get("tags") or "")}
    groups: dict[str, dict] = {}

    def suggest_by_content(text: str) -> dict:
        try:
            best = call(api, "POST", "/api/projects/match", {"text": text[:20000]}).get("best") or {}
        except Exception:  # noqa: BLE001
            best = {}
        if best.get("project_id") and best.get("confidence") in ("high", "medium") and best["project_id"] not in catch_all:
            return {"action": "existing", "project_id": best["project_id"], "project_name": projects.get(best["project_id"], "")}
        return {}

    for s in sessions:
        if not is_broad(s["folder"]):
            key = s["folder"].rstrip("/")
            group = groups.setdefault(key, {"key": key, "folder": key, "label": os.path.basename(key) or key, "sessions": []})
            group["sessions"].append(s)
            continue
        # No project folder: decide session by session from what was said. Chats already in
        # Wolf Leader are skipped on import, so they are not worth a match.
        suggestion = {} if s["already_in"] else suggest_by_content(f"{s['title']}\n{s['said']}")
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
                # Decide each session from what was said. If most agree on one project, that is the
                # folder's project; if not, the folder is a mixed workspace and each session goes its own way.
                for s in group["sessions"]:
                    s["suggestion"] = suggest_by_content(f"{s['title']}\n{s['said']}") or None
                votes: dict[int, int] = {}
                for s in group["sessions"]:
                    if s["suggestion"]:
                        votes[s["suggestion"]["project_id"]] = votes.get(s["suggestion"]["project_id"], 0) + 1
                top = max(votes.items(), key=lambda kv: kv[1]) if votes else None
                if top and top[1] >= 0.7 * len(group["sessions"]):
                    group["suggestion"] = {"action": "existing", "project_id": top[0], "project_name": projects.get(top[0], "")}
                elif len(group["sessions"]) >= 6 and votes:
                    group["suggestion"] = {"action": "split"}
                else:
                    group["suggestion"] = {"action": "new",
                                           "name": re.sub(r"[-_]+", " ", group["label"]).strip().title() or "New project"}
        times = sorted(t for s in group["sessions"] for t in (s.get("started"), s.get("ended")) if t)
        group.update({
            "first": times[0] if times else None, "last": times[-1] if times else None,
            "count": len(group["sessions"]), "new": sum(1 for s in group["sessions"] if not s["already_in"]),
            "tools": sorted({s["tool"] for s in group["sessions"]}),
        })
        group["sessions"].sort(key=lambda s: s.get("started") or s.get("ended") or "")

    # A mixed folder becomes one group per project it touched, plus the rest left loose.
    for key in [k for k, g in groups.items() if g["suggestion"]["action"] == "split"]:
        mixed = groups.pop(key)
        for s in mixed["sessions"]:
            sg = s.get("suggestion")
            sub_key = f"project:{sg['project_id']}" if sg else "loose"
            sub = groups.setdefault(sub_key, {
                "key": sub_key, "folder": None, "label": sg["project_name"] if sg else "No clear project",
                "suggestion": sg or {"action": "loose"}, "sessions": [],
            })
            sub["sessions"].append(s)
            sub["from_mixed"] = mixed["label"]
        for sub in groups.values():
            if "count" not in sub or sub.get("from_mixed") == mixed["label"]:
                times = sorted(t for s in sub["sessions"] for t in (s.get("started"), s.get("ended")) if t)
                sub.update({"first": times[0] if times else None, "last": times[-1] if times else None,
                            "count": len(sub["sessions"]), "new": sum(1 for s in sub["sessions"] if not s["already_in"]),
                            "tools": sorted({s["tool"] for s in sub["sessions"]})})

    tools = {}
    for s in sessions:
        t = tools.setdefault(s["tool"], {"tool": s["tool"], "sessions": 0, "new": 0})
        t["sessions"] += 1
        t["new"] += 0 if s["already_in"] else 1
    ordered = sorted(groups.values(), key=lambda g: (g["key"] == "loose", -g["new"], g["label"].lower()))
    return {"tools": sorted(tools.values(), key=lambda t: t["tool"]), "groups": ordered,
            "exports": [str(p) for p in export_paths],
            "profile": profile_candidates(), "skills": local_skills()}


def profile_candidates() -> list[dict]:
    spec = importlib.util.spec_from_file_location("wl_profile_text", HERE.parent / "ide_storage" / "profile_text.py")
    if not spec or not spec.loader:
        return []
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    items_from_text = module.items_from_text
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
    skills: dict[str, dict] = {}
    for tool, root in SKILL_DIRS.items():
        if not root.is_dir():
            continue
        for skill in sorted(root.iterdir()):
            if not skill.name.startswith(".") and (skill / "SKILL.md").is_file():
                entry = skills.setdefault(skill.name, {"name": skill.name, "tools": [], "path": str(skill)})
                entry["tools"].append(tool)
    return sorted(skills.values(), key=lambda s: s["name"])


TOOL_HOMES = {"claude": HOME / ".claude", "codex": HOME / ".codex", "cursor": HOME / ".cursor"}
START, END = "<!-- wolf-leader-profile:start -->", "<!-- wolf-leader-profile:end -->"


def tool_status() -> list[dict]:
    """Which AI tools are on this computer, and whether each one already talks to Wolf Leader."""
    def has(path: Path, needle: str) -> bool:
        try:
            return needle in path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return False
    mcp = {
        "claude": has(HOME / ".claude.json", "wolf-leader"),
        "codex": has(HOME / ".codex" / "config.toml", "wolf-leader"),
        "cursor": has(HOME / ".cursor" / "mcp.json", "wolf-leader"),
    }
    names = {"claude": "Claude Code", "codex": "Codex", "cursor": "Cursor"}
    out = []
    for tool, home in TOOL_HOMES.items():
        skills = SKILL_DIRS[tool]
        out.append({"tool": tool, "name": names[tool], "installed": home.is_dir(), "connected": mcp[tool],
                    "skills": sum(1 for d in skills.iterdir() if (d / "SKILL.md").is_file()) if skills.is_dir() else 0,
                    "has_profile": profile_block_present(tool)})
    return out


def profile_target(tool: str) -> Path:
    return {"claude": HOME / ".claude" / "CLAUDE.md", "codex": HOME / ".codex" / "AGENTS.md",
            "cursor": HOME / ".cursor" / "rules" / "wolf-leader-profile.mdc"}[tool]


def profile_block_present(tool: str) -> bool:
    try:
        return START in profile_target(tool).read_text(encoding="utf-8")
    except OSError:
        return False


def write_profile(tool: str, markdown: str) -> str:
    """Put the profile into the file this tool reads at the start of every chat. Only the marked
    block is ever replaced; anything the person wrote around it stays."""
    target = profile_target(tool)
    block = f"{START}\n{markdown.strip()}\n{END}"
    if tool == "cursor":
        text = "---\ndescription: Who I am and how I like to work (from Wolf Leader)\nalwaysApply: true\n---\n\n" + block + "\n"
    else:
        try:
            old = target.read_text(encoding="utf-8")
        except OSError:
            old = ""
        if START in old and END in old:
            text = old[:old.index(START)] + block + old[old.index(END) + len(END):]
        else:
            text = (old.rstrip() + "\n\n" if old.strip() else "") + block + "\n"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    return str(target)


def send_to_tools(api: str, person: str, tools: list[str]) -> dict:
    """Give the chosen tools the person's profile, so switching tools loses nothing."""
    result: dict = {"profile": []}
    tools = [t for t in tools if t in TOOL_HOMES and TOOL_HOMES[t].is_dir()]
    if person:
        req = urllib.request.Request(api + f"/api/people/{urllib.parse.quote(person)}/profile.md")
        with urllib.request.urlopen(req, timeout=30) as resp:
            markdown = resp.read().decode("utf-8")
        for tool in tools:
            result["profile"].append({"tool": tool, "file": write_profile(tool, markdown)})
    return result


BACKUPS = HOME / ".wolf-leader" / "skill-backups"


def _tree_digest(folder: Path) -> str:
    import hashlib
    digest = hashlib.sha256()
    for path in sorted(folder.rglob("*")):
        if path.is_file() and not any(part in ("__pycache__", ".DS_Store", ".git") for part in path.parts):
            digest.update(path.relative_to(folder).as_posix().encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def _put_aside(path: Path, tool: str) -> str:
    """Move a skill out of a tool's folder into a dated backup. Nothing is deleted outright."""
    import shutil
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = BACKUPS / stamp / tool / path.name
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(path), str(dest))
    return str(dest)


def skill_overview(api: str) -> dict:
    """The master set kept in Wolf Leader, and what each AI tool on this Mac has."""
    master = call(api, "GET", "/api/skills").get("skills", [])
    names = {m["id"] for m in master}
    tools = []
    for tool, root in SKILL_DIRS.items():
        if not TOOL_HOMES[tool].is_dir():
            continue
        have = sorted(d.name for d in root.iterdir()
                      if not d.name.startswith(".") and (d / "SKILL.md").is_file()) if root.is_dir() else []
        tools.append({"tool": tool, "skills": [{"name": n, "in_set": n in names} for n in have],
                      "missing": sorted(names - set(have))})
    return {"master": [{"id": m["id"], "name": m.get("name") or m["id"], "description": m.get("description") or "",
                        "tools": [t["tool"] for t in tools if m["id"] not in t["missing"]]} for m in master],
            "tools": tools,
            "not_in_set": sorted({s["name"] for t in tools for s in t["skills"] if not s["in_set"]})}


def push_skills(api: str) -> dict:
    """Write every skill in the master set into every AI tool on this Mac. A tool's own copy that
    differs is replaced; the old copy is kept under ~/.wolf-leader/skill-backups."""
    import io
    import shutil
    import tempfile
    import zipfile
    req = urllib.request.Request(api + "/api/skills/export.zip")
    with urllib.request.urlopen(req, timeout=120) as resp:
        archive = zipfile.ZipFile(io.BytesIO(resp.read()))
    added, updated, same = [], [], 0
    with tempfile.TemporaryDirectory() as tmp:
        archive.extractall(tmp)  # zipfile drops ".." and absolute paths, so this stays inside tmp
        root = Path(tmp) / "skills"
        masters = [d for d in root.iterdir() if (d / "SKILL.md").is_file()] if root.is_dir() else []
        for tool, folder in SKILL_DIRS.items():
            if not TOOL_HOMES[tool].is_dir():
                continue
            folder.mkdir(parents=True, exist_ok=True)
            for skill in masters:
                dest = folder / skill.name
                if dest.exists() or dest.is_symlink():
                    if dest.is_dir() and _tree_digest(dest) == _tree_digest(skill):
                        same += 1
                        continue
                    _put_aside(dest, tool)
                    updated.append({"tool": tool, "skill": skill.name})
                else:
                    added.append({"tool": tool, "skill": skill.name})
                shutil.copytree(skill, dest)
    return {"added": added, "updated": updated, "unchanged": same, "backups": str(BACKUPS)}


def remove_skills(tool: str, names: list[str]) -> dict:
    root = SKILL_DIRS.get(tool)
    removed = []
    for name in names:
        path = root / name if root else None
        if path and (path / "SKILL.md").is_file() and "/" not in name and not name.startswith("."):
            _put_aside(path, tool)
            removed.append(name)
    return {"removed": removed, "backups": str(BACKUPS)}


def adopt_skills(api: str, names: list[str]) -> dict:
    """Add skills found in a tool to the master set in Wolf Leader."""
    import base64
    have = {s["name"]: s for s in local_skills()}
    added, skipped = [], []
    for name in names:
        found = have.get(name)
        if not found:
            skipped.append({"skill": name, "why": "not on this computer"})
            continue
        folder = Path(found["path"])
        files = [{"path": f"{name}/{p.relative_to(folder).as_posix()}",
                  "content_base64": base64.b64encode(p.read_bytes()).decode()}
                 for p in sorted(folder.rglob("*"))
                 if p.is_file() and not any(part in ("__pycache__", ".DS_Store", ".git") for part in p.parts)]
        try:
            call(api, "POST", "/api/skills/import", {"name": name.lower(), "files": files, "overwrite": False})
            added.append(name)
        except Exception as exc:  # noqa: BLE001
            skipped.append({"skill": name, "why": "already in your set" if "409" in str(exc) else str(exc)[:160]})
    return {"added": added, "skipped": skipped}


PROFILE_PROMPT = """Below is a summary of one person's work with AI tools: their projects and things they typed.
Write a short profile of them that any AI assistant should read before helping them.

Rules:
- Return only a JSON array, nothing else. Each item: {"kind": K, "text": T}.
- K is one of: about (who they are, what they make), preference (how they like to work),
  style (how they like answers written), tools (devices, apps and services they use),
  avoid (things an assistant should not do).
- T is one short sentence in the first person ("I ..."), under 160 characters.
- At most 15 items, about 1,500 characters in all. Only things that hold across projects,
  not details of one task.
- Leave out anything already listed under "Already in their profile".
- Never include passwords, keys, addresses, phone numbers, money details, or other people's private details."""


def find_ai_cli() -> tuple[str, str] | None:
    """Claude Code or Codex on this computer, if either is installed."""
    import shutil
    extra = [HOME / ".local" / "bin", HOME / ".claude" / "local", Path("/opt/homebrew/bin"), Path("/usr/local/bin"),
             HOME / ".npm-global" / "bin", HOME / ".bun" / "bin"]
    path = os.pathsep.join([os.environ.get("PATH", "")] + [str(d) for d in extra])
    for name in ("claude", "codex"):
        found = shutil.which(name, path=path)
        if found:
            return name, found
    return None


def _json_items(text: str) -> list[dict]:
    start, end = text.find("["), text.rfind("]")
    if start < 0 or end <= start:
        return []
    try:
        data = json.loads(text[start:end + 1])
    except json.JSONDecodeError:
        return []
    kinds = {"about", "preference", "style", "tools", "avoid"}
    return [{"kind": d["kind"] if d.get("kind") in kinds else "about", "text": " ".join(str(d["text"]).split())[:300]}
            for d in data if isinstance(d, dict) and str(d.get("text") or "").strip()][:20]


def draft_profile(api: str, person: str) -> dict:
    """Draft a profile from what Wolf Leader already holds. Uses the person's own AI tool when
    there is one; otherwise picks lines from their own words. Nothing is saved: they review it."""
    import subprocess
    import tempfile
    who = urllib.parse.quote(person)
    cli = find_ai_cli()
    if cli:
        digest = call(api, "GET", f"/api/people/{who}/profile/digest")
        name, binary = cli
        with tempfile.TemporaryDirectory() as tmp:
            out_file = Path(tmp) / "answer.txt"
            if name == "claude":
                args = [binary, "-p", PROFILE_PROMPT]
            else:
                args = [binary, "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only",
                        "-o", str(out_file), PROFILE_PROMPT]
            try:
                run = subprocess.run(args, input=digest["text"], capture_output=True, text=True, cwd=tmp, timeout=600)
                answer = out_file.read_text(encoding="utf-8") if out_file.is_file() else run.stdout
            except (OSError, subprocess.TimeoutExpired):
                answer = ""
        items = _json_items(answer)
        if items:
            return {"by": name, "items": [{**i, "source": "ai"} for i in items],
                    "looked_at": digest.get("messages", 0), "projects": digest.get("projects", 0)}
    found = call(api, "GET", f"/api/people/{who}/profile/suggestions")
    return {"by": "wolf", "items": found.get("items", []), "looked_at": found.get("looked_at", 0)}


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
            cutoff = datetime.fromtimestamp(datetime.now(timezone.utc).timestamp() - 30 * 86400).isoformat()
            stale = not recent or recent < cutoff
            made = call(api, "POST", "/api/projects/start", {
                "name": choice.get("name") or group["label"], "folder": group.get("folder") or "",
                "description": f"Brought in from {', '.join(group.get('tools', []))} history.",
                "status": "in_progress" if not stale else "done",
            })
            slugs[group["key"]] = made.get("slug")
            print(json.dumps({"event": "project", "name": made.get("name"), "slug": made.get("slug")}), flush=True)
        else:  # "one-offs" (older plans say "loose")
            slugs[group["key"]] = "one-offs"
    for group, session in todo:
        path = Path(session["path"])
        try:
            if session.get("export"):
                conv = next((c for c in read_export(path) if c["id"] == session["id"]), None)
                messages = [{"role": m["role"], "content": helpers.truncate(m["content"])} for m in (conv or {}).get("messages", [])]
            else:
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
    ap.add_argument("mode", choices=["scan", "import", "tools", "send", "skills", "push-skills", "remove-skills",
                                     "adopt-skills", "write-profile"])
    ap.add_argument("plan", nargs="?")
    ap.add_argument("--api", default=None)
    ap.add_argument("--person", default="")
    ap.add_argument("--export", action="append", default=[], help="scan: a Claude.ai or ChatGPT export zip or folder")
    ap.add_argument("--to", default="", help="send: tools, comma separated (claude,codex,cursor)")
    ap.add_argument("--skills", default="", help="skill names, comma separated")
    ap.add_argument("--tool", default="", help="remove-skills: the tool to remove them from")
    args = ap.parse_args()
    api = api_url(args.api)
    if args.mode == "tools":
        print(json.dumps({"tools": tool_status(), "skills": local_skills()}))
        return 0
    split = lambda v: [x.strip() for x in (v or "").split(",") if x.strip()]  # noqa: E731
    if args.mode == "send":
        print(json.dumps(send_to_tools(api, args.person, split(args.to))))
        return 0
    if args.mode == "write-profile":
        print(json.dumps(draft_profile(api, args.person)))
        return 0
    if args.mode == "skills":
        print(json.dumps(skill_overview(api)))
        return 0
    if args.mode == "push-skills":
        print(json.dumps(push_skills(api)))
        return 0
    if args.mode == "remove-skills":
        print(json.dumps(remove_skills(args.tool, split(args.skills))))
        return 0
    if args.mode == "adopt-skills":
        print(json.dumps(adopt_skills(api, split(args.skills))))
        return 0
    if args.mode == "scan":
        print(json.dumps(scan(api, args.export)))
        return 0
    if not args.plan:
        ap.error("import needs the plan file")
    return run_import(api, json.loads(Path(args.plan).read_text(encoding="utf-8")))


if __name__ == "__main__":
    raise SystemExit(main())
