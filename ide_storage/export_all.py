"""Export everything: one ZIP with all of a hub's projects, memories, chats, profile and skills.

Two copies of the same data, so it is useful with or without Wolf Leader:

- ``readable/`` — Markdown a person or any AI tool can read: one folder per project with its
  brief, memories and every chat.
- ``data/`` — every table as JSON lines, exact and complete, for moving to another hub or
  another tool.

Search indexes (embeddings, file chunks) are left out: they are rebuilt from the data.
"""

from __future__ import annotations

import json
import os
import re
import tempfile
import zipfile
from datetime import date, datetime
from decimal import Decimal
from typing import Any, Dict, Iterable, List

from .db import db_conn

# Everything that is the user's own. Not here: embeddings, file_chunks, fs_catalog, jobs
# (derived or temporary; rebuilt from the rest).
TABLES = [
    "projects", "project_paths", "chats", "messages", "memories", "howls", "goals", "milestones",
    "north_stars", "profile_items", "snippets", "app_chats", "app_settings", "knowledge_revisions",
    "build_prompts", "attachments", "offsite_copies",
]

README = """Wolf Leader export
==================

This is everything your Wolf Leader hub knows, in two forms.

readable/   Markdown you can open anywhere, or hand to any AI tool.
            profile.md              what Wolf Leader knows about you
            projects/<name>/        one folder per project:
              PROJECT.md            the project's brief
              memories.md           decisions, constraints, problems, notes
              chats/                every saved chat, oldest first
            loose-chats/            chats that are not in a project

data/       The same data, exact and complete: one <table>.jsonl file per table,
            one JSON object per line. Use this to move to another hub or tool.

skills/     Your skill library. Each folder is a complete skill.

Search indexes are not included; they are rebuilt from this data.
"""


def _plain(value: Any) -> Any:
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (bytes, memoryview)):
        return bytes(value).decode("utf-8", errors="replace")
    return value


def _rows(table: str, order: str = "id") -> Iterable[Dict[str, Any]]:
    """Every row of a table. A table an older hub doesn't have is simply empty."""
    with db_conn() as conn:
        cur = conn.cursor()
        try:
            cur.execute(f"SELECT * FROM {table} ORDER BY {order}")
        except Exception:
            try:
                conn.rollback()
                cur = conn.cursor()
                cur.execute(f"SELECT * FROM {table}")
            except Exception:
                return
        while True:
            batch = cur.fetchmany(500)
            if not batch:
                break
            for row in batch:
                yield {k: _plain(v) for k, v in dict(row).items()}


def _safe(name: str, fallback: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._ -]+", "-", (name or "").strip()).strip(" .-")
    return (cleaned or fallback)[:80]


def _when(row: Dict[str, Any]) -> str:
    for key in ("occurred_at", "created_at", "updated_at", "saved_at"):
        if row.get(key):
            return str(row[key])
    return ""


def _chat_markdown(chat: Dict[str, Any], messages: List[Dict[str, Any]]) -> str:
    lines = [f"# {chat.get('title') or 'Chat'}", ""]
    meta = [f"- When: {_when(chat)}" if _when(chat) else "", f"- Source: {chat.get('source')}" if chat.get("source") else "",
            f"- Device: {chat.get('device_name')}" if chat.get("device_name") else ""]
    lines += [m for m in meta if m]
    if chat.get("summary"):
        lines += ["", "## Summary", "", str(chat["summary"])]
    lines += ["", "## Conversation", ""]
    for message in messages:
        who = {"user": "You", "assistant": "AI"}.get(str(message.get("role") or ""), str(message.get("role") or "note").capitalize())
        lines += [f"**{who}:**", "", str(message.get("content") or "").strip(), ""]
    return "\n".join(lines).rstrip() + "\n"


def _memories_markdown(name: str, memories: List[Dict[str, Any]]) -> str:
    lines = [f"# {name}: memories", ""]
    by_type: Dict[str, List[Dict[str, Any]]] = {}
    for memory in memories:
        by_type.setdefault(str(memory.get("type") or "note"), []).append(memory)
    for kind in sorted(by_type):
        lines += [f"## {kind.replace('_', ' ').capitalize()}", ""]
        for memory in by_type[kind]:
            text = str(memory.get("content") or "").strip().replace("\n", "\n  ")
            if text:
                lines.append(f"- {text}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def write_export(path: str) -> Dict[str, int]:
    """Write the whole export to ``path``. Returns how many rows of each table went in."""
    from .markdown_sync import read_project_md

    counts: Dict[str, int] = {}
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("README.txt", README)

        # data/: every table, exactly.
        for table in TABLES:
            with archive.open(f"data/{table}.jsonl", "w") as handle:
                n = 0
                for row in _rows(table):
                    handle.write((json.dumps(row, ensure_ascii=False, default=str) + "\n").encode("utf-8"))
                    n += 1
                counts[table] = n

        # readable/: the same, as Markdown.
        projects = {p["id"]: p for p in _rows("projects")}
        folders: Dict[Any, str] = {}
        used: set = set()
        for pid, project in projects.items():
            folder = _safe(project.get("name") or "", f"project-{pid}")
            if folder.lower() in used:
                folder = f"{folder} ({pid})"
            used.add(folder.lower())
            folders[pid] = f"readable/projects/{folder}"
            brief = read_project_md(project.get("slug") or "") if project.get("slug") else ""
            if not brief.strip():
                brief = f"# {project.get('name')}\n\n{project.get('description') or ''}\n"
            archive.writestr(f"{folders[pid]}/PROJECT.md", brief)

        memories: Dict[Any, List[Dict[str, Any]]] = {}
        for memory in _rows("memories"):
            memories.setdefault(memory.get("project_id"), []).append(memory)
        for pid, items in memories.items():
            if pid in projects:
                archive.writestr(f"{folders[pid]}/memories.md", _memories_markdown(projects[pid].get("name") or "Project", items))

        messages: Dict[Any, List[Dict[str, Any]]] = {}
        for message in _rows("messages"):
            messages.setdefault(message.get("chat_id"), []).append(message)
        for chat in _rows("chats"):
            base = folders.get(chat.get("project_id"), "readable/loose-chats")
            sub = "" if base.endswith("loose-chats") else "/chats"
            stamp = _when(chat)[:10] or "undated"
            name = f"{stamp} {_safe(chat.get('title') or '', 'chat')[:60]} ({chat.get('id')}).md"
            archive.writestr(f"{base}{sub}/{name}", _chat_markdown(chat, messages.get(chat.get("id"), [])))

        profile = ["# Profile", ""]
        for item in _rows("profile_items"):
            who = item.get("person") or item.get("owner") or ""
            kind = item.get("kind") or item.get("type") or "note"
            text = str(item.get("content") or item.get("text") or "").strip()
            if text:
                profile.append(f"- **{kind}**{f' ({who})' if who else ''}: {text}")
        archive.writestr("readable/profile.md", "\n".join(profile) + "\n")

        # skills/: the library, as it is installed.
        try:
            from .skill_registry import _write_skill_to_zip, list_skills, skills_dir

            for skill in list_skills():
                _write_skill_to_zip(archive, skills_dir() / skill["id"], f"skills/{skill['id']}")
        except Exception:
            pass

        archive.writestr("data/counts.json", json.dumps(counts, indent=2))
    return counts


def export_to_temp() -> str:
    """Write the export to a temporary file and return its path; the caller removes it."""
    handle, path = tempfile.mkstemp(prefix="wolf-leader-export-", suffix=".zip")
    os.close(handle)
    try:
        write_export(path)
    except Exception:
        os.unlink(path)
        raise
    return path
