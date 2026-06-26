"""Sync project briefs and index to markdown files on disk."""
import os
from datetime import datetime
from typing import Any, Dict, List

from .branding import MCP_SERVER_KEY, PRODUCT_NAME, PRODUCT_TAGLINE
from .db import db_conn, get_projects_dir


def get_data_dir() -> str:
    return os.path.normpath(os.path.join(get_projects_dir(), ".."))


def read_project_md(slug: str) -> str:
    path = os.path.join(get_projects_dir(), slug, "PROJECT.md")
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    return ""


def write_project_md(slug: str, content: str) -> str:
    path_dir = os.path.join(get_projects_dir(), slug)
    os.makedirs(path_dir, exist_ok=True)
    path = os.path.join(path_dir, "PROJECT.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return path


def read_agent_brief(slug: str) -> str:
    path = os.path.join(get_projects_dir(), slug, "AGENT_BRIEF.md")
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    return ""


def write_agent_brief(slug: str, content: str) -> str:
    path_dir = os.path.join(get_projects_dir(), slug)
    os.makedirs(path_dir, exist_ok=True)
    path = os.path.join(path_dir, "AGENT_BRIEF.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return path


def agent_brief_mtime(slug: str) -> str | None:
    path = os.path.join(get_projects_dir(), slug, "AGENT_BRIEF.md")
    if not os.path.isfile(path):
        return None
    return datetime.utcfromtimestamp(os.path.getmtime(path)).isoformat()


def ensure_project_md_from_db(project: Dict[str, Any]) -> str:
    slug = project.get("slug") or f"project-{project['id']}"
    existing = read_project_md(slug)
    if existing.strip():
        return existing
    lines = [
        f"# {project.get('name', slug)}",
        "",
        f"**Status:** {project.get('status') or 'active'}",
    ]
    if project.get("compose_path"):
        lines.append(f"**Compose:** `{project['compose_path']}`")
    if project.get("path"):
        lines.append(f"**Path:** `{project['path']}`")
    lines.append("")
    if project.get("description"):
        lines.extend(["## Overview", "", project["description"], ""])
    lines.extend(
        [
            "## Key decisions",
            "",
            "_Add via web UI Memories or API `POST /api/memories`._",
            "",
            "## Open issues",
            "",
            "_None recorded._",
            "",
        ]
    )
    content = "\n".join(lines)
    write_project_md(slug, content)
    return content


def regenerate_index() -> str:
    public = os.environ.get("IDE_STORAGE_PUBLIC_URL", "http://127.0.0.1:6971").rstrip("/")
    compose = os.environ.get(
        "IDE_STORAGE_COMPOSE_PATH",
        "/boot/config/plugins/compose.manager/projects/wolf-leader",
    )
    now = datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT p.*,
                   (SELECT COUNT(*) FROM chats c WHERE c.project_id = p.id) AS chat_count,
                   (SELECT COUNT(*) FROM memories m WHERE m.project_id = p.id) AS memory_count
            FROM projects p
            WHERE COALESCE(p.status, 'active') != 'archived'
            ORDER BY p.updated_at DESC
            """
        )
        projects = [dict(r) for r in cur.fetchall()]
        cur.execute(
            """
            SELECT c.id, c.title, c.updated_at, c.project_id, p.slug AS project_slug
            FROM chats c
            LEFT JOIN projects p ON c.project_id = p.id
            WHERE COALESCE(c.status, 'active') != 'archived'
            ORDER BY c.updated_at DESC
            LIMIT 30
            """
        )
        recent_chats = [dict(r) for r in cur.fetchall()]

    lines = [
        f"# {PRODUCT_NAME} — {PRODUCT_TAGLINE}",
        "",
        f"_Auto-generated {now}_",
        "",
        f"**Web UI:** {public}",
        f"**Setup (new devices):** [{public}/?tab=setup]({public}/?tab=setup)",
        f"**ONBOARDING.md:** `{compose}/data/ONBOARDING.md`",
        f"**AGENTS.md:** `{compose}/data/AGENTS.md`",
        "",
        "## Projects",
        "",
    ]
    if not projects:
        lines.append("_No projects yet._")
    else:
        for p in projects:
            slug = p.get("slug") or f"project-{p['id']}"
            lines.append(f"### [{p['name']}]({public}/?project={p['id']}) (`{slug}`)")
            if p.get("compose_path"):
                lines.append(f"- Compose: `{p['compose_path']}`")
            lines.append(
                f"- Sessions: {p.get('chat_count', 0)} | Memories: {p.get('memory_count', 0)}"
            )
            lines.append(f"- Brief: `data/projects/{slug}/PROJECT.md`")
            lines.append("")

    lines.extend(["## Recent sessions", ""])
    if not recent_chats:
        lines.append("_No chats yet._")
    else:
        for c in recent_chats:
            title = c.get("title") or f"Chat #{c['id']}"
            proj = f" ({c['project_slug']})" if c.get("project_slug") else ""
            lines.append(
                f"- [{title}]({public}/?chat={c['id']}){proj} — {(c.get('updated_at') or '')[:10]}"
            )

    content = "\n".join(lines) + "\n"
    index_path = os.path.join(get_data_dir(), "INDEX.md")
    with open(index_path, "w", encoding="utf-8") as f:
        f.write(content)
    return content


def read_index_md() -> str:
    index_path = os.path.join(get_data_dir(), "INDEX.md")
    if os.path.isfile(index_path):
        with open(index_path, encoding="utf-8", errors="replace") as f:
            return f.read()
    return regenerate_index()


def read_onboarding_md() -> str:
    path = os.path.join(get_data_dir(), "ONBOARDING.md")
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    return f"# {PRODUCT_NAME} onboarding\n\nONBOARDING.md not found on hub.\n"


def read_save_project_md() -> str:
    path = os.path.join(get_data_dir(), "SAVE_PROJECT.md")
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    return f"# Save to {PRODUCT_NAME}\n\nSAVE_PROJECT.md not found on hub.\n"
