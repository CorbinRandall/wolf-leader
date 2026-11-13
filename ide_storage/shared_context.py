"""Shared projects: context every project gets.

A project marked shared (``projects.metadata.shared = true``) holds things that apply
everywhere, such as the servers on a home network and how to reach them. Its PROJECT.md and
memories are handed to every chat and every recall, whatever project that chat is in, so
the same facts do not have to be copied into each project.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from .db import db_conn
from .left_off import parse_metadata

MEMORY_ORDER = ["constraint", "decision", "goal", "active_work", "problem", "caveat", "note"]
MAX_MEMORIES = 60
MAX_PROJECT_MD = 8000


def is_shared(project: Dict[str, Any]) -> bool:
    return bool(parse_metadata(project.get("metadata")).get("shared"))


def shared_projects() -> List[Dict[str, Any]]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT * FROM projects
            WHERE COALESCE(status, 'active') != 'archived' AND metadata IS NOT NULL
            ORDER BY name
            """
        )
        rows = [dict(r) for r in cur.fetchall()]
    return [r for r in rows if is_shared(r)]


def _memories(project_id: int) -> List[Dict[str, Any]]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, type, content, updated_at FROM memories WHERE project_id = ? ORDER BY updated_at DESC",
            (project_id,),
        )
        rows = [dict(r) for r in cur.fetchall() if (r["content"] or "").strip()]
    rank = {t: i for i, t in enumerate(MEMORY_ORDER)}
    rows.sort(key=lambda m: rank.get(m.get("type") or "note", len(rank)))
    return rows[:MAX_MEMORIES]


def _project_md(slug: str) -> str:
    from .markdown_sync import read_project_md

    text = (read_project_md(slug) or "").strip()
    return text if len(text) <= MAX_PROJECT_MD else text[:MAX_PROJECT_MD] + "\n…"


def shared_context(exclude_project_id: Optional[int] = None) -> List[Dict[str, Any]]:
    """Each shared project's notes and memories, skipping the project the chat is already in."""
    out = []
    for p in shared_projects():
        if exclude_project_id is not None and int(p["id"]) == int(exclude_project_id):
            continue
        slug = p.get("slug") or f"project-{p['id']}"
        out.append(
            {
                "project_id": p["id"],
                "slug": slug,
                "name": p.get("name"),
                "description": p.get("description") or "",
                "project_md": _project_md(slug),
                "memories": [{"id": m["id"], "type": m["type"], "content": m["content"]} for m in _memories(p["id"])],
            }
        )
    return out


def shared_context_text(exclude_project_id: Optional[int] = None) -> str:
    """The same, as one block of text an agent can read."""
    blocks = []
    for s in shared_context(exclude_project_id):
        parts = [f"## {s['name']}"]
        if s["description"]:
            parts.append(s["description"])
        if s["project_md"]:
            parts.append(s["project_md"])
        if s["memories"]:
            parts.append("\n".join(f"- {m['type']}: {m['content'].strip()}" for m in s["memories"]))
        blocks.append("\n\n".join(parts))
    return "\n\n".join(blocks)
