"""Wolf Leader MCP server — agent tools for AI project storage."""
import json
import logging
import os
from typing import Any, Dict, List, Optional

from fastmcp import Context, FastMCP

from . import hub
from .branding import MCP_SERVER_KEY, PRODUCT_DESCRIPTION, PRODUCT_NAME
from .db import db_conn
from .markdown_sync import regenerate_index

logger = logging.getLogger(f"{MCP_SERVER_KEY}.mcp")

mcp = FastMCP(
    name=PRODUCT_NAME,
    instructions=(
        f"{PRODUCT_DESCRIPTION} "
        "ALWAYS call resolve_project or set_project, then recall at session start. "
        "Call remember for decisions/constraints. Call save_session at session end."
    ),
)

# Active project is per-session, not global: concurrent clients (multiple devices
# /IDEs) each hit this one server, so a shared global would bleed across sessions.
_active_by_session: Dict[str, Dict[str, Any]] = {}


def _sess_key(ctx: Optional[Context]) -> str:
    sid = getattr(ctx, "session_id", None) if ctx is not None else None
    return sid or "_default"


def _get_active(ctx: Optional[Context]) -> Dict[str, Any]:
    return _active_by_session.setdefault(
        _sess_key(ctx), {"project_id": None, "slug": None, "path": None}
    )


@mcp.tool
def set_project(
    slug: Optional[str] = None,
    project_id: Optional[int] = None,
    compose_path: Optional[str] = None,
    ctx: Context = None,
) -> dict:
    """Set the active project for this session by slug, id, or compose path."""
    project = hub.resolve_project(slug=slug, project_id=project_id, path=compose_path)
    if not project:
        return {"ok": False, "error": "Project not found"}
    active = _get_active(ctx)
    active["project_id"] = project["id"]
    active["slug"] = project.get("slug")
    active["path"] = project.get("compose_path") or project.get("path")
    return {
        "ok": True,
        "project_id": project["id"],
        "slug": project.get("slug"),
        "name": project.get("name"),
        "compose_path": project.get("compose_path"),
    }


@mcp.tool
def resolve_project(path: str, ctx: Context = None) -> dict:
    """Match a workspace or compose folder path to a registered project."""
    project = hub.resolve_project(path=path)
    if not project:
        return {"matched": False, "path": path}
    active = _get_active(ctx)
    active["project_id"] = project["id"]
    active["slug"] = project.get("slug")
    active["path"] = path
    return {
        "matched": True,
        "project_id": project["id"],
        "slug": project.get("slug"),
        "name": project.get("name"),
        "compose_path": project.get("compose_path"),
    }


@mcp.tool
def recall(
    slug: Optional[str] = None,
    project_id: Optional[int] = None,
    path: Optional[str] = None,
    memory_types: Optional[str] = None,
    ctx: Context = None,
) -> dict:
    """
    Load project context: PROJECT.md, typed memories, recent sessions.
    Uses active project if no args given.
    memory_types: comma-separated e.g. 'decision,constraint,active_work'
    """
    active = _get_active(ctx)
    pid = project_id or active.get("project_id")
    pslug = slug or active.get("slug")
    ppath = path or active.get("path")
    types = [t.strip() for t in memory_types.split(",")] if memory_types else None
    return hub.recall_project(path=ppath, slug=pslug, project_id=pid, memory_types=types)


@mcp.tool
def remember(
    content: str,
    type: str = "note",
    project_id: Optional[int] = None,
    source_chat_id: Optional[int] = None,
    semantic_descriptor: Optional[str] = None,
    ctx: Context = None,
) -> dict:
    """Store a typed memory (decision, constraint, active_work, problem, goal, note, caveat)."""
    pid = project_id or _get_active(ctx).get("project_id")
    if not pid:
        return {"ok": False, "error": "No project set — call set_project or resolve_project first"}
    try:
        result = hub.remember(
            pid, type, content, source_chat_id=source_chat_id, semantic_descriptor=semantic_descriptor
        )
        return {"ok": True, **result}
    except ValueError as e:
        return {"ok": False, "error": str(e)}


@mcp.tool
def list_projects() -> dict:
    """List all active projects in the hub."""
    return {"projects": hub.list_projects_hub(), "count": len(hub.list_projects_hub())}


@mcp.tool
def search(query: str, limit: int = 15) -> dict:
    """Search projects, memories, and chats (hybrid keyword + vector when enabled)."""
    return hub.hub_search(query, limit)


@mcp.tool
def get_session(chat_id: Optional[int] = None, session_id: Optional[str] = None) -> dict:
    """Fetch a stored chat session with all messages."""
    with db_conn() as conn:
        cur = conn.cursor()
        if chat_id:
            cur.execute("SELECT * FROM chats WHERE id = ?", (chat_id,))
        elif session_id:
            cur.execute("SELECT * FROM chats WHERE session_id = ?", (session_id,))
        else:
            return {"error": "Provide chat_id or session_id"}
        row = cur.fetchone()
        if not row:
            return {"error": "Chat not found"}
        chat = dict(row)
        cur.execute(
            "SELECT * FROM messages WHERE chat_id = ? ORDER BY id ASC",
            (chat["id"],),
        )
        chat["messages"] = [dict(m) for m in cur.fetchall()]
    return chat


@mcp.tool
def get_brief(
    slug: Optional[str] = None,
    project_id: Optional[int] = None,
    ctx: Context = None,
) -> dict:
    """Fetch distilled agent brief for a project (same as agent-brief API)."""
    active = _get_active(ctx)
    pid = project_id or active.get("project_id")
    pslug = slug or active.get("slug")
    if not pid and not pslug:
        return {"ok": False, "error": "No project set — call set_project or resolve_project first"}
    try:
        return hub.get_agent_brief_payload(project_id=pid, slug=pslug)
    except ValueError as e:
        return {"ok": False, "error": str(e)}


@mcp.tool
def save_current_session(
    session_id: Optional[str] = None,
    slug: Optional[str] = None,
    workspace_path: Optional[str] = None,
    ctx: Context = None,
) -> dict:
    """
    Save the current chat to Wolf Leader: sync transcript, auto-link project,
    extract memories, refresh SPEC/brief, archive session. Use when user says save/save project.
    """
    from ide_storage.save_project import format_save_summary, save_project

    active = _get_active(ctx)
    try:
        report = save_project(
            session_id,
            project_slug=slug or active.get("slug"),
            workspace_path=workspace_path or active.get("path"),
        )
        return {"ok": report.get("ok", False), "summary": format_save_summary(report), **report}
    except Exception as e:
        logger.exception("save_current_session failed")
        return {"ok": False, "error": str(e)}


@mcp.tool
def save_session(
    title: str,
    content: str,
    session_id: Optional[str] = None,
    workspace_path: Optional[str] = None,
    project_id: Optional[int] = None,
    messages_json: Optional[str] = None,
    ctx: Context = None,
) -> dict:
    """
    Save or update a chat session. messages_json: JSON array of {role, content}.
    Call at session end to persist work to the hub.
    """
    messages = None
    if messages_json:
        try:
            messages = json.loads(messages_json)
        except json.JSONDecodeError:
            return {"ok": False, "error": "Invalid messages_json"}
    pid = project_id or _get_active(ctx).get("project_id")
    try:
        result = hub.save_session_with_pipeline(
            title=title,
            content=content,
            session_id=session_id,
            workspace_path=workspace_path,
            project_id=pid,
            messages=messages,
        )
        regenerate_index()
        return {"ok": True, **result}
    except Exception as e:
        logger.exception("save_session failed")
        return {"ok": False, "error": str(e)}


def mount_on_fastapi(fastapi_app) -> None:
    """MCP runs on separate port (6972) — see mcp_standalone.py."""
    logger.info("MCP available on port %s (standalone)", os.environ.get("MCP_PORT", "6972"))
