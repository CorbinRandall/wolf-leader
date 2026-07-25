"""Shared hub logic for REST API and MCP tools."""
import json
import os
import re
from datetime import datetime
from typing import Any, Dict, List, Optional

from .branding import SERVICE_ID
from .context import (
    build_agent_start_prompt,
    build_project_agent_context,
    format_project_context_text,
    get_service_config,
)
from .db import MEMORY_TYPES, db_conn
from .markdown_sync import (
    agent_brief_mtime,
    ensure_project_md_from_db,
    read_agent_brief,
    read_project_md,
)


def normalize_path(path: str) -> str:
    return os.path.normpath(path.rstrip("/"))


def resolve_project(
    path: Optional[str] = None,
    slug: Optional[str] = None,
    project_id: Optional[int] = None,
) -> Optional[Dict[str, Any]]:
    with db_conn() as conn:
        cur = conn.cursor()
        if project_id is not None:
            cur.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
            row = cur.fetchone()
            return dict(row) if row else None

        if slug:
            cur.execute("SELECT * FROM projects WHERE slug = ?", (slug,))
            row = cur.fetchone()
            return dict(row) if row else None

        if not path:
            return None

        norm = normalize_path(path)
        cur.execute(
            """
            SELECT * FROM projects
            WHERE COALESCE(status, 'active') != 'archived'
            """
        )
        best, best_len = None, 0
        for row in cur.fetchall():
            project = dict(row)
            for key in ("compose_path", "path"):
                val = project.get(key)
                if not val:
                    continue
                vnorm = normalize_path(val)
                if norm == vnorm or norm.startswith(vnorm + os.sep):
                    if len(vnorm) > best_len:
                        best = project
                        best_len = len(vnorm)
        return best


def resolve_project_key(key: str) -> Optional[Dict[str, Any]]:
    """Resolve project by numeric id or slug string."""
    if key.isdigit():
        return resolve_project(project_id=int(key))
    return resolve_project(slug=key)


def get_agent_brief_payload(project_id: Optional[int] = None, slug: Optional[str] = None) -> Dict[str, Any]:
    import re

    from .context import build_agent_brief_response
    from .distill_spec import read_spec_yaml, spec_mtime
    from .handoff import parse_spec_handoff
    from .markdown_sync import agent_brief_mtime, read_agent_brief
    from .preflight import run_preflight
    from .project_archetypes import get_continue_mode, get_deploy_state, pickup_prompt

    project = resolve_project(project_id=project_id, slug=slug)
    if not project:
        raise ValueError("Project not found")
    pid = project["id"]
    pslug = project.get("slug") or f"project-{pid}"
    md = read_project_md(pslug) or ensure_project_md_from_db(project)
    brief_md = read_agent_brief(pslug)
    spec_yaml = read_spec_yaml(pslug)
    continue_mode = get_continue_mode(project)

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, title, content, updated_at, session_id
            FROM chats WHERE project_id = ? AND COALESCE(status, 'active') != 'archived'
            ORDER BY updated_at DESC
            """,
            (pid,),
        )
        chats = [dict(r) for r in cur.fetchall()]
        cur.execute(
            """
            SELECT id, type, content, updated_at FROM memories
            WHERE project_id = ? AND COALESCE(status, 'active') = 'active'
            ORDER BY updated_at DESC
            """,
            (pid,),
        )
        memories = [dict(r) for r in cur.fetchall()]
        archived_count = _archived_session_count(cur, pid)
        archived_recent = _recent_archived_sessions(cur, pid, 2)

    discovered_paths: list[str] = []
    path_m = re.findall(
        r'^\s+-\s+"(/[^"]+)"',
        spec_yaml if spec_yaml else "",
        re.MULTILINE,
    )
    discovered_paths.extend(path_m)
    preflight = run_preflight(
        project,
        slug=pslug,
        continue_mode=continue_mode,
        discovered_paths=discovered_paths or None,
    )
    ctx = build_project_agent_context(
        project, chats, memories, md,
        archived_session_count=archived_count,
        archived_recent_sessions=archived_recent,
        continue_mode=continue_mode,
        preflight_compose_path=preflight.get("compose_path"),
    )
    cfg = get_service_config()
    handoff = parse_spec_handoff(spec_yaml)
    pickup_from_spec = None
    m = re.search(r'^pickup:\s*"((?:[^"\\]|\\.)*)"', spec_yaml, re.MULTILINE)
    if m:
        pickup_from_spec = m.group(1).replace('\\"', '"')

    drill_down = _drill_down_from_spec(handoff, cfg.get("public_base_url", ""))
    public_base = cfg.get("public_base_url", "http://127.0.0.1:6971")
    brief_url = f"{public_base.rstrip('/')}/api/projects/{pslug}/agent-brief"
    default_pickup = pickup_from_spec or pickup_prompt(project, public_base=public_base)
    from .left_off import left_off_payload, log_entry_from_chat, resolve_pickup

    with db_conn() as conn:
        cur = conn.cursor()
        log_rows = _activity_log_sessions(cur, pid, 25)

    public = public_base.rstrip("/")
    entries = []
    for row in log_rows:
        entry = log_entry_from_chat(row)
        entry["web"] = f"{public}/?chat={row['id']}"
        entries.append(entry)

    pickup_prompt_resolved, _ = resolve_pickup(
        project, default_pickup=default_pickup, brief_url=brief_url
    )
    left_off = left_off_payload(
        project,
        brief_url=brief_url,
        log_entries=entries,
        default_pickup=default_pickup,
    )
    # Prefer resolved pickup that includes latest log when metadata empty
    if left_off.get("pickup"):
        pickup_prompt_resolved = left_off["pickup"]

    payload = build_agent_brief_response(
        project,
        chats,
        memories,
        md,
        brief_md,
        brief_updated_at=agent_brief_mtime(pslug) or spec_mtime(pslug),
        ctx=ctx,
        spec_yaml=spec_yaml,
        continue_mode=continue_mode,
        deploy_state=handoff.get("observed_deploy_state") or get_deploy_state(project),
        pickup_prompt=pickup_prompt_resolved,
        handoff_tier=handoff.get("handoff_tier"),
        drill_down=drill_down,
        preflight=preflight,
    )
    payload["where_we_left_off"] = left_off
    payload["activity_log"] = entries
    return payload


def _drill_down_from_spec(handoff: Dict[str, Any], public_base: str) -> Dict[str, Any]:
    """Build drill_down payload with resolvable chat URLs."""
    required = handoff.get("drill_down_required") or []
    optional = handoff.get("drill_down_optional") or []
    base = (public_base or "http://127.0.0.1:6971").rstrip("/")
    urls: Dict[str, str] = {}
    for ref in required + optional:
        m = re.match(r"chat:(\d+)", ref)
        if m:
            urls[ref] = f"{base}/api/chats/{m.group(1)}"
    return {"required": required, "optional": optional, "urls": urls}


def _project_chats(cur, project_id: int, limit: int = 5) -> List[Dict[str, Any]]:
    cur.execute(
        """
        SELECT id, title, content, updated_at, session_id
        FROM chats
        WHERE project_id = ? AND COALESCE(status, 'active') != 'archived'
        ORDER BY updated_at DESC LIMIT ?
        """,
        (project_id, limit),
    )
    return [dict(r) for r in cur.fetchall()]


def _archived_session_count(cur, project_id: int) -> int:
    cur.execute(
        """
        SELECT COUNT(*) FROM chats
        WHERE project_id = ? AND COALESCE(status, 'active') = 'archived'
        """,
        (project_id,),
    )
    return cur.fetchone()[0]


def _recent_archived_sessions(cur, project_id: int, limit: int = 2) -> List[Dict[str, Any]]:
    cur.execute(
        """
        SELECT id, title, content, updated_at, created_at, occurred_at FROM chats
        WHERE project_id = ? AND COALESCE(status, 'active') = 'archived'
        ORDER BY COALESCE(occurred_at, created_at, updated_at) DESC LIMIT ?
        """,
        (project_id, limit),
    )
    return [dict(r) for r in cur.fetchall()]


def _activity_log_sessions(cur, project_id: int, limit: int = 25) -> List[Dict[str, Any]]:
    """Archived session summaries for the user-facing logbook (session timeline order)."""
    cur.execute(
        """
        SELECT id, title, content, metadata, updated_at, created_at, occurred_at FROM chats
        WHERE project_id = ? AND COALESCE(status, 'active') = 'archived'
        ORDER BY COALESCE(occurred_at, created_at, updated_at) DESC LIMIT ?
        """,
        (project_id, limit),
    )
    return [dict(r) for r in cur.fetchall()]


def _project_memories(cur, project_id: int, limit: int = 30) -> List[Dict[str, Any]]:
    cur.execute(
        """
        SELECT id, type, content, updated_at FROM memories
        WHERE project_id = ? AND COALESCE(status, 'active') = 'active'
        ORDER BY updated_at DESC LIMIT ?
        """,
        (project_id, limit),
    )
    return [dict(r) for r in cur.fetchall()]


def get_bootstrap(
    path: Optional[str] = None,
    slug: Optional[str] = None,
    project_id: Optional[int] = None,
) -> Dict[str, Any]:
    cfg = {
        "service": SERVICE_ID,
        "mcp_url": os.environ.get(
            "IDE_STORAGE_MCP_URL", "http://127.0.0.1:6972/mcp"
        ),
        "agents_md": os.environ.get(
            "IDE_STORAGE_AGENTS_MD",
            os.path.join(
                os.environ.get("IDE_STORAGE_COMPOSE_PATH", "/app"),
                "data",
                "AGENTS.md",
            ),
        ),
        "onboarding_url": os.environ.get(
            "IDE_STORAGE_PUBLIC_URL", "http://127.0.0.1:6971"
        ).rstrip("/")
        + "/api/onboarding",
        "onboarding_web_url": os.environ.get(
            "IDE_STORAGE_PUBLIC_URL", "http://127.0.0.1:6971"
        ).rstrip("/")
        + "/?tab=setup",
    }

    project = resolve_project(path=path, slug=slug, project_id=project_id)
    if not project:
        with db_conn() as conn:
            cur = conn.cursor()
            cur.execute(
                """
                SELECT id, name, slug, compose_path FROM projects
                WHERE COALESCE(status, 'active') != 'archived'
                ORDER BY updated_at DESC LIMIT 10
                """
            )
            projects = [dict(r) for r in cur.fetchall()]
        return {
            "matched": False,
            "path": path,
            "config": cfg,
            "projects": projects,
            "instruction": "Call list_projects or set_project, then recall.",
        }

    pid = project["id"]
    pslug = project.get("slug") or f"project-{pid}"
    try:
        handoff = get_agent_brief_payload(project_id=pid)
    except ValueError:
        handoff = {}

    data = {
        "matched": True,
        "project": {
            "id": pid,
            "slug": pslug,
            "name": project.get("name"),
            "compose_path": project.get("compose_path"),
            "path": project.get("path"),
        },
        "config": cfg,
        **handoff,
    }
    data["agent_brief"] = handoff.get("brief_md") or read_agent_brief(pslug)
    data["recent_sessions"] = handoff.get("sessions") or []
    if not data.get("paste_text"):
        data["paste_text"] = format_project_context_text(
            build_project_agent_context(project, [], [], read_project_md(pslug) or "")
        )
    return data


def recall_project(
    path: Optional[str] = None,
    slug: Optional[str] = None,
    project_id: Optional[int] = None,
    memory_types: Optional[List[str]] = None,
) -> Dict[str, Any]:
    data = get_bootstrap(path=path, slug=slug, project_id=project_id)
    if not data.get("matched"):
        return data
    if memory_types:
        data["memories"] = [
            m for m in data.get("memories", []) if m.get("type") in memory_types
        ]
    return data


def remember(
    project_id: int,
    type: str,
    content: str,
    source_chat_id: Optional[int] = None,
    semantic_descriptor: Optional[str] = None,
) -> Dict[str, Any]:
    from .memory_ops import remember_and_refresh

    return remember_and_refresh(
        project_id,
        type,
        content,
        source_chat_id=source_chat_id,
        semantic_descriptor=semantic_descriptor,
    )


def list_projects_hub(limit: int = 100) -> List[Dict[str, Any]]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT p.*,
                   (SELECT COUNT(*) FROM chats c WHERE c.project_id = p.id) AS chat_count,
                   (SELECT COUNT(*) FROM memories m WHERE m.project_id = p.id) AS memory_count
            FROM projects p
            WHERE COALESCE(p.status, 'active') != 'archived'
            ORDER BY p.updated_at DESC LIMIT ?
            """,
            (limit,),
        )
        return [dict(r) for r in cur.fetchall()]


def save_session(
    title: str,
    content: str,
    session_id: Optional[str] = None,
    workspace_path: Optional[str] = None,
    project_id: Optional[int] = None,
    messages: Optional[List[Dict[str, str]]] = None,
    device_name: str = "unraid-server",
    occurred_at: Optional[str] = None,
    transcript_mtime: Optional[float] = None,
) -> Dict[str, Any]:
    from .session_time import infer_occurred_at, parse_datetime, isoformat_utc

    now = datetime.utcnow().isoformat()
    messages = messages or []
    occurred = infer_occurred_at(
        explicit=occurred_at,
        title=title,
        messages=messages,
        created_at=now,
        transcript_mtime=transcript_mtime,
    )

    if project_id is None and workspace_path:
        proj = resolve_project(path=workspace_path)
        if proj:
            project_id = proj["id"]

    with db_conn() as conn:
        cur = conn.cursor()
        existing_id = None
        if session_id:
            cur.execute("SELECT id, occurred_at, created_at FROM chats WHERE session_id = ?", (session_id,))
            row = cur.fetchone()
            if row:
                existing_id = row["id"]
                # Keep earlier occurred_at if we already know a better session time.
                existing_occ = (row["occurred_at"] or "").strip()
                if existing_occ and (not occurred or existing_occ <= occurred):
                    occurred = existing_occ

        if existing_id:
            cur.execute(
                """
                UPDATE chats SET title = ?, content = ?, project_id = ?,
                    workspace_path = ?, updated_at = ?, occurred_at = COALESCE(?, occurred_at)
                WHERE id = ?
                """,
                (title, content, project_id, workspace_path, now, occurred, existing_id),
            )
            chat_id = existing_id
            action = "updated"
        else:
            cur.execute(
                """
                INSERT INTO chats (title, workspace_path, device_name, session_id,
                    project_id, created_at, updated_at, content, status, occurred_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)
                """,
                (
                    title,
                    workspace_path,
                    device_name,
                    session_id,
                    project_id,
                    now,
                    now,
                    content,
                    occurred,
                ),
            )
            chat_id = cur.lastrowid
            action = "created"

        added = 0
        for msg in messages:
            msg_time = isoformat_utc(parse_datetime(msg.get("created_at") if isinstance(msg, dict) else None)) or occurred or now
            cur.execute(
                """
                INSERT INTO messages (chat_id, role, content, created_at, metadata)
                VALUES (?, ?, ?, ?, NULL)
                """,
                (chat_id, msg.get("role", "user"), msg.get("content", ""), msg_time),
            )
            added += 1

        conn.commit()

    return {
        "id": chat_id,
        "action": action,
        "messages_added": added,
        "session_id": session_id,
        "occurred_at": occurred,
    }


def save_session_with_pipeline(
    title: str,
    content: str,
    session_id: Optional[str] = None,
    workspace_path: Optional[str] = None,
    project_id: Optional[int] = None,
    messages: Optional[List[Dict[str, str]]] = None,
    device_name: str = "unraid-server",
    occurred_at: Optional[str] = None,
) -> Dict[str, Any]:
    result = save_session(
        title,
        content,
        session_id,
        workspace_path,
        project_id,
        messages,
        device_name,
        occurred_at=occurred_at,
    )
    if session_id:
        from .post_save_pipeline import post_save_pipeline

        result["pipeline"] = post_save_pipeline(session_id, sync=False)
    else:
        # C5: no session_id means the pipeline (which embeds the chat) doesn't run.
        # Still embed the saved chat directly so the vector index isn't skipped.
        from .embeddings import embeddings_enabled

        if embeddings_enabled() and result.get("id"):
            from .embed_index import sync_dirty

            result["embeddings"] = sync_dirty(
                chat_ids=[result["id"]], project_id=project_id
            )
    return result


def hub_search(query: str, limit: int = 20, include_archived: bool = False) -> Dict[str, Any]:
    from ide_storage.search_ops import hybrid_search

    return hybrid_search(query, limit=limit, include_archived=include_archived, hub_mode=True)
