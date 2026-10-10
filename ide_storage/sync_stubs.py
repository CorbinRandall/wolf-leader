"""Generate IDE_CONTEXT.md stubs in compose project folders."""
import os
import re
from typing import Any, Dict, List

from .branding import MCP_SERVER_KEY, PRODUCT_NAME, PRODUCT_TAGLINE
from .context import get_service_config
from .db import db_conn

COMPOSE_ROOT = os.environ.get(
    "COMPOSE_MANAGER_ROOT",
    "/boot/config/plugins/compose.manager/projects",
)
STUB_NAME = "IDE_CONTEXT.md"


def _slugify(name: str) -> str:
    s = name.lower().strip()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return s.strip("-")[:64] or "project"


def scan_compose_folders() -> List[Dict[str, str]]:
    """Discover compose projects not yet in DB."""
    if not os.path.isdir(COMPOSE_ROOT):
        return []
    discovered = []
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT compose_path, path FROM projects")
        known = set()
        for row in cur.fetchall():
            for key in ("compose_path", "path"):
                if row[key]:
                    known.add(os.path.normpath(row[key]))

        for entry in sorted(os.listdir(COMPOSE_ROOT)):
            folder = os.path.join(COMPOSE_ROOT, entry)
            if not os.path.isdir(folder):
                continue
            if not os.path.isfile(os.path.join(folder, "docker-compose.yml")):
                continue
            norm = os.path.normpath(folder)
            if norm in known:
                continue
            discovered.append({"name": entry, "compose_path": norm, "slug": _slugify(entry)})
    return discovered


def register_compose_projects() -> int:
    """Auto-register compose folders as projects. Returns count added."""
    from datetime import datetime

    now = datetime.utcnow().isoformat()
    added = 0
    new_ids: list[int] = []
    with db_conn() as conn:
        cur = conn.cursor()
        for item in scan_compose_folders():
            cur.execute("SELECT id FROM projects WHERE slug = ?", (item["slug"],))
            if cur.fetchone():
                continue
            cur.execute(
                """
                INSERT INTO projects (name, path, description, slug, status, compose_path,
                    created_at, updated_at)
                VALUES (?, ?, ?, ?, 'active', ?, ?, ?)
                """,
                (
                    item["name"],
                    item["compose_path"],
                    f"Compose stack: {item['name']}",
                    item["slug"],
                    item["compose_path"],
                    now,
                    now,
                ),
            )
            new_ids.append(int(cur.lastrowid))
            added += 1
        conn.commit()

    # C4: embed newly registered projects so they're searchable immediately — but
    # ONLY when embeddings are enabled, so startup stays fast on the lean image
    # (this runs at boot via the FastAPI lifespan).
    if new_ids:
        from .embeddings import embeddings_enabled

        if embeddings_enabled():
            from .embed_index import sync_dirty

            for pid in new_ids:
                sync_dirty(project_id=pid)
    return added


def write_stub(project: Dict[str, Any]) -> str:
    compose = project.get("compose_path") or project.get("path") or ""
    slug = project.get("slug") or f"project-{project['id']}"
    if not compose or not os.path.isdir(compose):
        return ""
    if not os.access(compose, os.W_OK):
        return ""
    cfg = get_service_config()
    public = cfg["public_base_url"]
    onboarding_path = cfg["onboarding_host_path"]
    body = f"""# {PRODUCT_NAME} — project context

This file links this compose stack to the centralized {PRODUCT_NAME} hub ({PRODUCT_TAGLINE}).

| Field | Value |
|-------|-------|
| **slug** | `{slug}` |
| **project_id** | {project['id']} |
| **compose_path** | `{compose}` |
| **Web UI** | {public}/?project={project['id']} |

## For any AI agent

**Session start:**
1. MCP `{MCP_SERVER_KEY}` → `set_project({{ slug: "{slug}" }})` → `get_brief()` or `recall()`
2. Fallback (same host shell): `curl -s {cfg['local_base_url']}/api/projects/{slug}/agent-brief`

**Session end:**
- Type `/save` or MCP `save_session` — checkpoint project (memories + brief); session archived

**Setup (new devices):** {cfg['onboarding_web_url']}
**Hub docs:** `{onboarding_path}`

Do not guess paths or redo prior work — recall first.
"""
    path = os.path.join(compose, STUB_NAME)
    with open(path, "w", encoding="utf-8") as f:
        f.write(body)
    return path


def sync_all_stubs() -> List[str]:
    """Write IDE_CONTEXT.md for every active project with a compose_path."""
    written = []
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT * FROM projects
            WHERE COALESCE(status, 'active') != 'archived'
            """
        )
        for row in cur.fetchall():
            p = write_stub(dict(row))
            if p:
                written.append(p)
    return written
