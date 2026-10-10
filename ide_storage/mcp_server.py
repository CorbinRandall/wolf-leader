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
        "Background memory for the user; they never type commands for it. "
        "Start: resolve_project(path) then recall(). If unmatched, tell the user in one line and ask "
        "before create_project(path). During work: remember() each decision/constraint/fix; "
        "save_session() after each meaningful step and at least every ~8 turns (same session_id = update). "
        "Mention what was saved in one short line; surface any error or ambiguity and ask."
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
def create_project(
    path: str,
    name: Optional[str] = None,
    slug: Optional[str] = None,
    device_name: Optional[str] = None,
    ctx: Context = None,
) -> dict:
    """
    Create a project for a workspace folder when resolve_project found none, and make it active.
    Name/slug default to the folder name. Idempotent: returns the existing match if one appears.
    Ask the user before calling this (one line: "No project for <folder>; create '<name>'?").
    """
    try:
        project = hub.create_project_for_path(path, name=name, slug=slug, device_name=device_name)
    except Exception as e:
        logger.exception("create_project failed")
        return {"ok": False, "error": str(e)}
    active = _get_active(ctx)
    active["project_id"] = project["id"]
    active["slug"] = project.get("slug")
    active["path"] = path
    return {
        "ok": True,
        "created": bool(project.get("created")),
        "project_id": project["id"],
        "slug": project.get("slug"),
        "name": project.get("name"),
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
    occurred_at: Optional[str] = None,
    ctx: Context = None,
) -> dict:
    """
    Checkpoint the current chat (create or update by session_id): stores title + summary content,
    replaces the transcript if messages_json is given, extracts memories, embeds, refreshes brief,
    vault note and wiki. Safe to call repeatedly — after each meaningful step and at least every
    ~8 turns. messages_json: JSON array of {role, content}. occurred_at: ISO time the chat happened.
    Always pass the real Cursor/Claude session_id so re-saves update instead of duplicating.
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
            occurred_at=occurred_at,
        )
        regenerate_index()
        return {"ok": True, **result}
    except Exception as e:
        logger.exception("save_session failed")
        return {"ok": False, "error": str(e)}


@mcp.tool
def wolfhowl(
    title: Optional[str] = None,
    messages_json: Optional[str] = None,
    session_id: Optional[str] = None,
    workspace_path: Optional[str] = None,
    slug: Optional[str] = None,
    device_name: Optional[str] = None,
    git_json: Optional[str] = None,
    cited_paths_json: Optional[str] = None,
    ingest_cited: bool = False,
    ctx: Context = None,
) -> dict:
    """
    Broadcast this session: /save + path alias + git state + embed + file catalog + Obsidian notes.
    messages_json: JSON array of {role, content}. git_json: {commit, branch, remote, dirty_files, is_repo}.
    Returns a summary paragraph and offers[] to ask the user about (commit, ingest files, jobs).
    """
    from .howl import run_howl

    def _load(raw: Optional[str], what: str):
        if not raw:
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            raise ValueError(f"Invalid {what}")

    try:
        messages = _load(messages_json, "messages_json")
        git = _load(git_json, "git_json")
        cited = _load(cited_paths_json, "cited_paths_json")
        active = _get_active(ctx)
        report = run_howl(
            session_id=session_id,
            slug=slug or active.get("slug"),
            workspace_path=workspace_path or active.get("path"),
            title=title,
            messages=messages,
            device_name=device_name,
            git=git,
            cited_paths=cited,
            ingest_cited=ingest_cited,
        )
        if report.get("project_id"):
            active["project_id"] = report["project_id"]
            active["slug"] = report.get("project_slug")
        return report
    except Exception as e:
        logger.exception("wolfhowl failed")
        return {"ok": False, "error": str(e)}


@mcp.tool
def wolfeat(
    slug: Optional[str] = None,
    project_id: Optional[int] = None,
    workspace_path: Optional[str] = None,
    device_name: Optional[str] = None,
    query: Optional[str] = None,
    ctx: Context = None,
) -> dict:
    """
    Pull the latest context for a project onto this machine: brief, memories, howls (with git SHAs),
    related notes, open jobs, plus offers[] (git pull, register path, read files, model pull).
    """
    from .howl import run_eat

    active = _get_active(ctx)
    result = run_eat(
        slug=slug or active.get("slug"),
        project_id=project_id or active.get("project_id"),
        workspace_path=workspace_path or active.get("path"),
        device_name=device_name,
        query=query,
    )
    if result.get("ok"):
        active["project_id"] = result["project_id"]
        active["slug"] = result.get("slug")
    return result


def mount_on_fastapi(fastapi_app) -> None:
    """MCP runs on separate port (6972) — see mcp_standalone.py."""
    logger.info("MCP available on port %s (standalone)", os.environ.get("MCP_PORT", "6972"))
