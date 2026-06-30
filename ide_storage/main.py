"""
Wolf Leader REST API — AI project storage (chats, projects, memories, briefs).
"""
import logging
import os
from datetime import datetime
from typing import List, Optional, Dict, Any

from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
import uvicorn

from .branding import MCP_SERVER_KEY, PRODUCT_NAME, PRODUCT_TAGLINE, SERVICE_ID

from .context import (
    build_agent_context,
    build_project_agent_context,
    format_agent_context_text,
    format_project_context_text,
    get_service_config,
)
from .db import MEMORY_TYPES, init_db, db_conn
from .markdown_sync import (
    agent_brief_mtime,
    ensure_project_md_from_db,
    read_agent_brief,
    read_index_md,
    read_onboarding_md,
    read_save_project_md,
    read_project_md,
    regenerate_index,
    write_project_md,
)
from .distill_project import distill_all, distill_project
from .distill_spec import distill_all_specs, distill_spec
from .post_save_pipeline import post_save_pipeline
from . import hub
from .seed import seed_if_needed
from .sync_stubs import register_compose_projects, sync_all_stubs

STATIC_DIR = Path(__file__).parent / "static"

# Configure logging
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(SERVICE_ID)


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    seed_if_needed()
    added = register_compose_projects()
    if added:
        logger.info("Auto-registered %d compose projects", added)
    stubs = sync_all_stubs()
    logger.info("Synced %d IDE_CONTEXT.md stubs", len(stubs))
    logger.info("Database initialized")
    yield


app = FastAPI(title=PRODUCT_NAME, description=PRODUCT_TAGLINE, version="1.0.0", lifespan=lifespan)

# Enable CORS for cross-device access
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

if STATIC_DIR.is_dir():
    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

# Pydantic models
class MessageCreate(BaseModel):
    role: str  # 'user' or 'assistant'
    content: str
    metadata: Optional[Dict[str, Any]] = None


class ChatCreate(BaseModel):
    title: Optional[str] = None
    workspace_path: Optional[str] = None
    device_name: Optional[str] = None
    session_id: Optional[str] = None  # Unique identifier for this chat session
    content: Optional[str] = None  # Optional summary/description
    messages: Optional[List[MessageCreate]] = None  # Full message history
    metadata: Optional[Dict[str, Any]] = None


class ChatUpdate(BaseModel):
    title: Optional[str] = None
    content: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None
    project_id: Optional[int] = None
    status: Optional[str] = None
    tags: Optional[List[str]] = None
    workspace_path: Optional[str] = None
    session_id: Optional[str] = None


class MessageUpdate(BaseModel):
    role: Optional[str] = None
    content: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None


class ProjectCreate(BaseModel):
    name: str
    path: str
    description: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None
    slug: Optional[str] = None
    status: Optional[str] = "active"
    compose_path: Optional[str] = None
    tags: Optional[List[str]] = None


class ProjectUpdate(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None
    slug: Optional[str] = None
    status: Optional[str] = None
    compose_path: Optional[str] = None
    path: Optional[str] = None
    tags: Optional[List[str]] = None


class ProjectMdUpdate(BaseModel):
    content: str


class SaveMessage(BaseModel):
    role: str
    content: str


class SaveProjectBody(BaseModel):
    session_id: Optional[str] = None
    slug: Optional[str] = None
    workspace_path: Optional[str] = None
    title: Optional[str] = None
    content: Optional[str] = None
    messages: Optional[List[SaveMessage]] = None


class ProjectMatchBody(BaseModel):
    text: Optional[str] = None
    messages: Optional[List[SaveMessage]] = None
    workspace_path: Optional[str] = None
    min_score: Optional[int] = None
    min_lead: Optional[int] = None
    limit: Optional[int] = 5


class MemoryCreate(BaseModel):
    project_id: int
    type: str
    content: str
    source_chat_id: Optional[int] = None
    semantic_descriptor: Optional[str] = None


class MemoryUpdate(BaseModel):
    type: Optional[str] = None
    content: Optional[str] = None
    semantic_descriptor: Optional[str] = None


class SnippetCreate(BaseModel):
    title: Optional[str] = None
    language: Optional[str] = None
    content: str
    project_id: Optional[int] = None
    tags: Optional[List[str]] = None


class SnippetUpdate(BaseModel):
    title: Optional[str] = None
    language: Optional[str] = None
    content: Optional[str] = None
    tags: Optional[List[str]] = None


@app.get("/")
async def web_ui():
    """Chat directory web UI."""
    index = STATIC_DIR / "index.html"
    if index.is_file():
        return FileResponse(index)
    return {"message": f"{PRODUCT_NAME} API", "docs": "/docs"}


@app.get("/api/config")
async def api_config():
    """Public service configuration for the web UI and agents."""
    cfg = get_service_config()
    cfg["mcp_url"] = os.environ.get(
        "IDE_STORAGE_MCP_URL", "http://127.0.0.1:6972/mcp"
    )
    cfg["product_name"] = PRODUCT_NAME
    cfg["product_tagline"] = PRODUCT_TAGLINE
    cfg["mcp_server_key"] = MCP_SERVER_KEY
    return cfg


@app.get("/api/bootstrap")
async def api_bootstrap(
    path: Optional[str] = None,
    slug: Optional[str] = None,
    project_id: Optional[int] = None,
):
    """One-call context bundle for session start (IDE-agnostic)."""
    return hub.get_bootstrap(path=path, slug=slug, project_id=project_id)


@app.get("/api/projects/resolve")
async def api_resolve_project(path: str):
    """Match a workspace/compose path to a project."""
    project = hub.resolve_project(path=path)
    if not project:
        raise HTTPException(status_code=404, detail="No matching project")
    return project


@app.post("/api/projects/match")
async def api_match_projects(body: ProjectMatchBody = ProjectMatchBody()):
    """Rank existing projects against conversation text (for /save auto-detect)."""
    from ide_storage.project_match import match_projects_payload

    messages = None
    if body.messages:
        messages = [{"role": m.role, "content": m.content} for m in body.messages]

    return match_projects_payload(
        messages=messages,
        text=body.text,
        workspace_path=body.workspace_path,
        min_score=body.min_score or 45,
        min_lead=body.min_lead or 12,
        limit=body.limit or 5,
    )


@app.post("/api/projects/sync-stubs")
async def api_sync_stubs():
    """Regenerate IDE_CONTEXT.md in all compose project folders."""
    added = register_compose_projects()
    written = sync_all_stubs()
    regenerate_index()
    return {"registered": added, "stubs_written": len(written), "paths": written}


# Chat endpoints
@app.post("/api/chats")
async def create_chat(chat: ChatCreate):
    """Create a new chat/conversation or update existing one if session_id matches."""
    now = datetime.utcnow().isoformat()
    import json
    metadata_json = json.dumps(chat.metadata) if chat.metadata else None
    
    with db_conn() as conn:
        cur = conn.cursor()
        
        # If session_id is provided, check if a chat with that session_id already exists
        existing_chat_id = None
        if chat.session_id:
            cur.execute(
                "SELECT id FROM chats WHERE session_id = ?",
                (chat.session_id,)
            )
            result = cur.fetchone()
            if result:
                existing_chat_id = result["id"]
                logger.info(f"Found existing chat {existing_chat_id} for session_id {chat.session_id}")
        
        if existing_chat_id:
            # Update existing chat
            chat_id = existing_chat_id
            
            # Update chat metadata if provided
            updates = []
            params = []
            
            auto_save = (chat.metadata or {}).get("auto_save") is True
            if chat.title is not None and not auto_save:
                updates.append("title = ?")
                params.append(chat.title)
            
            if chat.content is not None:
                updates.append("content = ?")
                params.append(chat.content)
            
            if chat.metadata is not None:
                updates.append("metadata = ?")
                params.append(metadata_json)
            
            updates.append("updated_at = ?")
            params.append(now)
            params.append(chat_id)
            
            if updates:
                cur.execute(
                    f"UPDATE chats SET {', '.join(updates)} WHERE id = ?",
                    params
                )
            
            # Add new messages to existing chat
            new_message_count = 0
            if chat.messages:
                for msg in chat.messages:
                    msg_metadata_json = json.dumps(msg.metadata) if msg.metadata else None
                    cur.execute(
                        """
                        INSERT INTO messages (chat_id, role, content, created_at, metadata)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        (chat_id, msg.role, msg.content, now, msg_metadata_json)
                    )
                    new_message_count += 1
            
            conn.commit()
            return {
                "id": chat_id,
                "message": "Chat updated successfully",
                "messages_count": new_message_count,
                "action": "updated"
            }
        else:
            # Create new chat
            # Generate summary from messages if content not provided but messages exist
            content = chat.content
            if not content and chat.messages:
                # Create a simple summary from first few messages
                preview = chat.messages[0].content[:200] if chat.messages else ""
                content = f"Conversation with {len(chat.messages)} messages. Preview: {preview}..."
            
            cur.execute(
                """
                INSERT INTO chats (title, workspace_path, device_name, session_id, created_at, updated_at, content, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (chat.title, chat.workspace_path, chat.device_name, chat.session_id, now, now, content, metadata_json)
            )
            chat_id = cur.lastrowid
            
            # Insert messages if provided
            if chat.messages:
                for msg in chat.messages:
                    msg_metadata_json = json.dumps(msg.metadata) if msg.metadata else None
                    cur.execute(
                        """
                        INSERT INTO messages (chat_id, role, content, created_at, metadata)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        (chat_id, msg.role, msg.content, now, msg_metadata_json)
                    )
            
            conn.commit()
            return {
                "id": chat_id,
                "message": "Chat created successfully",
                "messages_count": len(chat.messages) if chat.messages else 0,
                "action": "created"
            }


@app.get("/api/search")
async def global_search(
    q: str,
    limit: int = 50,
    include_archived: bool = False,
    kinds: Optional[str] = None,
):
    """Hybrid keyword + vector search. kinds: comma-separated subset of memory,project,chat,message."""
    from ide_storage.search_ops import hybrid_search, _parse_kinds

    return hybrid_search(
        q,
        limit=limit,
        include_archived=include_archived,
        hub_mode=False,
        kinds=_parse_kinds(kinds),
    )


@app.get("/api/chats")
async def list_chats(
    workspace_path: Optional[str] = None,
    device_name: Optional[str] = None,
    project_id: Optional[int] = None,
    status: Optional[str] = None,
    include_archived: bool = False,
    limit: int = 100,
    offset: int = 0
):
    """List chats with optional filtering. Default: active only."""
    with db_conn() as conn:
        cur = conn.cursor()
        
        query = """
            SELECT c.*,
                   (SELECT COUNT(*) FROM messages m WHERE m.chat_id = c.id) AS message_count,
                   p.name AS project_name, p.slug AS project_slug
            FROM chats c
            LEFT JOIN projects p ON p.id = c.project_id
            WHERE 1=1
        """
        params = []
        
        if workspace_path:
            query += " AND c.workspace_path = ?"
            params.append(workspace_path)
        
        if device_name:
            query += " AND c.device_name = ?"
            params.append(device_name)

        if project_id is not None:
            query += " AND c.project_id = ?"
            params.append(project_id)

        if status:
            query += " AND COALESCE(c.status, 'active') = ?"
            params.append(status)
        elif not include_archived:
            query += " AND COALESCE(c.status, 'active') = 'active'"
        
        query += " ORDER BY c.updated_at DESC LIMIT ? OFFSET ?"
        params.extend([limit, offset])
        
        cur.execute(query, params)
        rows = cur.fetchall()
        
        chats = [dict(row) for row in rows]
        return {"chats": chats, "count": len(chats)}


@app.get("/api/chats/{chat_id}")
async def get_chat(chat_id: int, include_messages: bool = False):
    """Get a specific chat by ID, optionally including all messages."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM chats WHERE id = ?", (chat_id,))
        row = cur.fetchone()
        
        if not row:
            raise HTTPException(status_code=404, detail="Chat not found")
        
        chat_data = dict(row)
        
        if include_messages:
            cur.execute(
                "SELECT * FROM messages WHERE chat_id = ? ORDER BY created_at ASC",
                (chat_id,)
            )
            messages = [dict(msg) for msg in cur.fetchall()]
            chat_data["messages"] = messages
            chat_data["message_count"] = len(messages)
        
        return chat_data


@app.get("/api/chats/{chat_id}/agent-context")
async def get_agent_context(chat_id: int):
    """Return structured reference + paste-ready text for a fresh agent session."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM chats WHERE id = ?", (chat_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Chat not found")

        cur.execute(
            "SELECT COUNT(*) AS cnt FROM messages WHERE chat_id = ?",
            (chat_id,),
        )
        message_count = cur.fetchone()["cnt"]

    chat = dict(row)
    ctx = build_agent_context(chat, message_count)
    ctx["paste_text"] = format_agent_context_text(ctx)
    return ctx


@app.put("/api/chats/{chat_id}")
async def update_chat(chat_id: int, chat: ChatUpdate):
    """Update a chat."""
    import json
    
    updates = []
    params = []
    
    if chat.title is not None:
        updates.append("title = ?")
        params.append(chat.title)
    
    if chat.content is not None:
        updates.append("content = ?")
        params.append(chat.content)
    
    if chat.metadata is not None:
        updates.append("metadata = ?")
        params.append(json.dumps(chat.metadata))

    if chat.project_id is not None:
        updates.append("project_id = ?")
        params.append(chat.project_id)

    if chat.status is not None:
        updates.append("status = ?")
        params.append(chat.status)

    if chat.tags is not None:
        updates.append("tags = ?")
        params.append(json.dumps(chat.tags))

    if chat.workspace_path is not None:
        updates.append("workspace_path = ?")
        params.append(chat.workspace_path)

    if chat.session_id is not None:
        updates.append("session_id = ?")
        params.append(chat.session_id)
    
    if not updates:
        raise HTTPException(status_code=400, detail="No fields to update")
    
    updates.append("updated_at = ?")
    params.append(datetime.utcnow().isoformat())
    params.append(chat_id)
    
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            f"UPDATE chats SET {', '.join(updates)} WHERE id = ?",
            params
        )
        conn.commit()
        
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Chat not found")

    regenerate_index()
    return {"message": "Chat updated successfully"}


@app.delete("/api/chats/{chat_id}")
async def delete_chat(chat_id: int):
    """Delete a chat and all its messages (CASCADE)."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM chats WHERE id = ?", (chat_id,))
        conn.commit()
        
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Chat not found")

    regenerate_index()
    return {"message": "Chat deleted successfully"}


# Message endpoints
@app.post("/api/chats/{chat_id}/messages")
async def add_message(chat_id: int, message: MessageCreate):
    """Add a message to an existing chat."""
    now = datetime.utcnow().isoformat()
    import json
    msg_metadata_json = json.dumps(message.metadata) if message.metadata else None
    
    # Verify chat exists
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id FROM chats WHERE id = ?", (chat_id,))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Chat not found")
        
        # Insert message
        cur.execute(
            """
            INSERT INTO messages (chat_id, role, content, created_at, metadata)
            VALUES (?, ?, ?, ?, ?)
            """,
            (chat_id, message.role, message.content, now, msg_metadata_json)
        )
        message_id = cur.lastrowid
        
        # Update chat's updated_at timestamp
        cur.execute(
            "UPDATE chats SET updated_at = ? WHERE id = ?",
            (now, chat_id)
        )
        
        conn.commit()
    
    return {"id": message_id, "message": "Message added successfully"}


@app.get("/api/chats/{chat_id}/messages")
async def get_messages(
    chat_id: int,
    role: Optional[str] = None,
    search: Optional[str] = None,
    limit: int = 1000,
    offset: int = 0
):
    """Get messages from a chat with optional filtering."""
    with db_conn() as conn:
        cur = conn.cursor()
        
        # Verify chat exists
        cur.execute("SELECT id FROM chats WHERE id = ?", (chat_id,))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Chat not found")
        
        query = "SELECT * FROM messages WHERE chat_id = ?"
        params = [chat_id]
        
        if role:
            query += " AND role = ?"
            params.append(role)
        
        if search:
            query += " AND content LIKE ?"
            params.append(f"%{search}%")
        
        query += " ORDER BY created_at ASC LIMIT ? OFFSET ?"
        params.extend([limit, offset])
        
        cur.execute(query, params)
        messages = [dict(row) for row in cur.fetchall()]
        
        return {"messages": messages, "count": len(messages)}


@app.put("/api/messages/{message_id}")
async def update_message(message_id: int, body: MessageUpdate):
    import json
    updates, params = [], []
    if body.role is not None:
        updates.append("role = ?")
        params.append(body.role)
    if body.content is not None:
        updates.append("content = ?")
        params.append(body.content)
    if body.metadata is not None:
        updates.append("metadata = ?")
        params.append(json.dumps(body.metadata))
    if not updates:
        raise HTTPException(status_code=400, detail="No fields to update")
    params.append(message_id)
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(f"UPDATE messages SET {', '.join(updates)} WHERE id = ?", params)
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Message not found")
        cur.execute("SELECT chat_id FROM messages WHERE id = ?", (message_id,))
        row = cur.fetchone()
        if row:
            cur.execute(
                "UPDATE chats SET updated_at = ? WHERE id = ?",
                (datetime.utcnow().isoformat(), row["chat_id"]),
            )
        conn.commit()
    return {"message": "Message updated successfully"}


@app.delete("/api/messages/{message_id}")
async def delete_message(message_id: int):
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT chat_id FROM messages WHERE id = ?", (message_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Message not found")
        chat_id = row["chat_id"]
        cur.execute("DELETE FROM messages WHERE id = ?", (message_id,))
        cur.execute(
            "UPDATE chats SET updated_at = ? WHERE id = ?",
            (datetime.utcnow().isoformat(), chat_id),
        )
        conn.commit()
    return {"message": "Message deleted successfully"}


@app.get("/api/chats/{chat_id}/summarize")
async def summarize_chat(chat_id: int, max_length: int = 500):
    """Generate a summary of the chat conversation."""
    with db_conn() as conn:
        cur = conn.cursor()
        
        # Get chat info
        cur.execute("SELECT * FROM chats WHERE id = ?", (chat_id,))
        chat = cur.fetchone()
        if not chat:
            raise HTTPException(status_code=404, detail="Chat not found")
        
        chat_dict = dict(chat)
        
        # Get all messages
        cur.execute(
            "SELECT role, content FROM messages WHERE chat_id = ? ORDER BY created_at ASC",
            (chat_id,)
        )
        messages = cur.fetchall()
        
        if not messages:
            return {
                "chat_id": chat_id,
                "summary": chat_dict.get("content", "No messages in this chat."),
                "message_count": 0,
                "method": "existing_summary"
            }
        
        # Generate summary
        user_messages = [msg["content"] for msg in messages if msg["role"] == "user"]
        assistant_messages = [msg["content"] for msg in messages if msg["role"] == "assistant"]
        
        summary_parts = []
        summary_parts.append(f"Conversation with {len(messages)} messages ({len(user_messages)} user, {len(assistant_messages)} assistant).")
        
        if user_messages:
            first_user_msg = user_messages[0][:200]
            summary_parts.append(f"Started with: {first_user_msg}...")
        
        if assistant_messages:
            # Get key points from assistant messages (first 100 chars of each)
            key_points = []
            for msg in assistant_messages[:3]:  # First 3 assistant messages
                preview = msg[:150].replace("\n", " ")
                key_points.append(preview)
            if key_points:
                summary_parts.append(f"Key responses: {' | '.join(key_points)}")
        
        summary = " ".join(summary_parts)
        
        # Truncate if too long
        if len(summary) > max_length:
            summary = summary[:max_length] + "..."
        
        return {
            "chat_id": chat_id,
            "summary": summary,
            "message_count": len(messages),
            "user_message_count": len(user_messages),
            "assistant_message_count": len(assistant_messages),
            "method": "generated"
        }


@app.get("/api/chats/{chat_id}/query")
async def query_chat(
    chat_id: int,
    q: str,
    role: Optional[str] = None,
    limit: int = 10
):
    """Search for specific content within a chat's messages."""
    with db_conn() as conn:
        cur = conn.cursor()
        
        # Verify chat exists
        cur.execute("SELECT id FROM chats WHERE id = ?", (chat_id,))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Chat not found")
        
        query = """
            SELECT id, role, content, created_at 
            FROM messages 
            WHERE chat_id = ? AND content LIKE ?
        """
        params = [chat_id, f"%{q}%"]
        
        if role:
            query += " AND role = ?"
            params.append(role)
        
        query += " ORDER BY created_at ASC LIMIT ?"
        params.append(limit)
        
        cur.execute(query, params)
        results = [dict(row) for row in cur.fetchall()]
        
        return {
            "query": q,
            "chat_id": chat_id,
            "results": results,
            "count": len(results)
        }


# Project endpoints
@app.post("/api/projects")
async def create_project(project: ProjectCreate):
    """Create a new project."""
    now = datetime.utcnow().isoformat()
    import json
    metadata_json = json.dumps(project.metadata) if project.metadata else None
    tags_json = json.dumps(project.tags) if project.tags else None
    slug = project.slug or project.name.lower().replace(" ", "-")[:64]
    
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO projects (name, path, description, slug, status, compose_path,
                tags, created_at, updated_at, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                project.name, project.path, project.description, slug,
                project.status or "active", project.compose_path, tags_json,
                now, now, metadata_json,
            ),
        )
        project_id = cur.lastrowid
        cur.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
        row = dict(cur.fetchone())
        conn.commit()

    ensure_project_md_from_db(row)
    regenerate_index()
    from ide_storage.embed_index import sync_dirty

    embed_report = sync_dirty(project_id=project_id)
    return {
        "id": project_id,
        "message": "Project created successfully",
        "embeddings": embed_report,
    }


@app.get("/api/projects")
async def list_projects(
    status: Optional[str] = None,
    limit: int = 100,
    offset: int = 0,
):
    """List all projects."""
    with db_conn() as conn:
        cur = conn.cursor()
        query = """
            SELECT p.*,
                   (SELECT COUNT(*) FROM chats c WHERE c.project_id = p.id) AS chat_count,
                   (SELECT COUNT(*) FROM memories m WHERE m.project_id = p.id) AS memory_count
            FROM projects p WHERE 1=1
        """
        params = []
        if status:
            query += " AND COALESCE(p.status, 'active') = ?"
            params.append(status)
        query += " ORDER BY p.updated_at DESC LIMIT ? OFFSET ?"
        params.extend([limit, offset])
        cur.execute(query, params)
        rows = cur.fetchall()
        projects = [dict(row) for row in rows]
        return {"projects": projects, "count": len(projects)}


@app.get("/api/projects/{project_id}")
async def get_project(project_id: int):
    """Get a specific project by ID."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
        row = cur.fetchone()
        
        if not row:
            raise HTTPException(status_code=404, detail="Project not found")
        
        return dict(row)


@app.put("/api/projects/{project_id}")
async def update_project(project_id: int, project: ProjectUpdate):
    """Update a project."""
    import json
    
    updates = []
    params = []
    
    if project.name is not None:
        updates.append("name = ?")
        params.append(project.name)
    
    if project.description is not None:
        updates.append("description = ?")
        params.append(project.description)
    
    if project.metadata is not None:
        updates.append("metadata = ?")
        params.append(json.dumps(project.metadata))

    if project.slug is not None:
        updates.append("slug = ?")
        params.append(project.slug)

    if project.status is not None:
        updates.append("status = ?")
        params.append(project.status)

    if project.compose_path is not None:
        updates.append("compose_path = ?")
        params.append(project.compose_path)

    if project.path is not None:
        updates.append("path = ?")
        params.append(project.path)

    if project.tags is not None:
        updates.append("tags = ?")
        params.append(json.dumps(project.tags))
    
    if not updates:
        raise HTTPException(status_code=400, detail="No fields to update")
    
    updates.append("updated_at = ?")
    params.append(datetime.utcnow().isoformat())
    params.append(project_id)
    
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            f"UPDATE projects SET {', '.join(updates)} WHERE id = ?",
            params
        )
        conn.commit()
        
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Project not found")

    regenerate_index()
    from ide_storage.embed_index import sync_dirty

    embed_report = sync_dirty(project_id=project_id)
    return {
        "message": "Project updated successfully",
        "embeddings": embed_report,
    }


@app.delete("/api/projects/{project_id}")
async def delete_project(project_id: int):
    """Delete a project."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM projects WHERE id = ?", (project_id,))
        conn.commit()
        
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Project not found")

    regenerate_index()
    return {"message": "Project deleted successfully"}


@app.get("/api/projects/{project_id}/chats")
async def project_chats(project_id: int, limit: int = 100, archived: bool = False):
    """Active sessions by default; ?archived=true for checkpoint archive."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id FROM projects WHERE id = ?", (project_id,))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Project not found")
        cur.execute(
            """
            SELECT COUNT(*) FROM chats
            WHERE project_id = ? AND COALESCE(status, 'active') = 'archived'
            """,
            (project_id,),
        )
        archived_count = cur.fetchone()[0]

    if archived:
        data = await list_chats(
            project_id=project_id, status="archived", include_archived=True, limit=limit
        )
        return {"archived": data["chats"], "archived_count": archived_count, "active": []}

    data = await list_chats(project_id=project_id, limit=limit)
    return {
        "active": data["chats"],
        "archived_count": archived_count,
        "count": len(data["chats"]),
    }


@app.get("/api/projects/{project_id}/context")
async def get_project_md(project_id: int):
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Project not found")
        project = dict(row)
    slug = project.get("slug") or f"project-{project_id}"
    content = read_project_md(slug) or ensure_project_md_from_db(project)
    return {"project_id": project_id, "slug": slug, "content": content}


@app.put("/api/projects/{project_id}/context")
async def put_project_md(project_id: int, body: ProjectMdUpdate):
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Project not found")
        project = dict(row)
        slug = project.get("slug") or f"project-{project_id}"
        path = write_project_md(slug, body.content)
        cur.execute(
            "UPDATE projects SET updated_at = ? WHERE id = ?",
            (datetime.utcnow().isoformat(), project_id),
        )
        conn.commit()
    regenerate_index()
    return {"message": "PROJECT.md updated", "path": path}


@app.get("/api/save-project-guide")
async def get_save_project_guide():
    """End-of-chat save instructions for any agent (Claude, Cursor, etc.)."""
    content = read_save_project_md()
    public = os.environ.get("IDE_STORAGE_PUBLIC_URL", "http://127.0.0.1:6971").rstrip("/")
    local = os.environ.get("IDE_STORAGE_LOCAL_URL", "http://127.0.0.1:6971").rstrip("/")
    return {
        "content": content,
        "agent_prompt": (
            f"Save this conversation to {PRODUCT_NAME}. "
            f"Fetch and follow every step: {public}/api/save-project-guide"
        ),
        "agent_prompt_local": (
            f"Save this conversation to {PRODUCT_NAME}. "
            f"Fetch and follow every step: {local}/api/save-project-guide"
        ),
        "save_url": f"{public}/api/save-project",
        "save_url_local": f"{local}/api/save-project",
        "mcp_url": os.environ.get("IDE_STORAGE_MCP_URL", "http://127.0.0.1:6972/mcp"),
    }


@app.post("/api/save-project")
async def save_project_checkpoint(body: SaveProjectBody = SaveProjectBody()):
    """
    End-of-chat save: Cursor transcript and/or in-context messages.
    Auto-detect project, checkpoint brief. See GET /api/save-project-guide.
    """
    from .save_project import format_save_summary, save_project

    messages = None
    if body.messages:
        messages = [{"role": m.role, "content": m.content} for m in body.messages]

    try:
        report = save_project(
            body.session_id,
            project_slug=body.slug,
            workspace_path=body.workspace_path,
            title=body.title,
            content=body.content,
            messages=messages,
        )
    except Exception as exc:
        logger.exception("save-project failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    report["summary"] = format_save_summary(report)
    if not report.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=report.get("summary") or report.get("error") or "Save failed",
        )
    return report


@app.post("/api/projects/distill-all")
async def distill_all_projects():
    """Regenerate SPEC.yaml and AGENT_BRIEF.md for every active project."""
    spec_results = distill_all_specs()
    results = distill_all()
    regenerate_index()
    return {
        "spec_distilled": len(spec_results),
        "distilled": len(results),
        "results": results,
        "spec_results": spec_results,
    }


@app.post("/api/projects/install-git-hooks")
async def install_compose_git_hooks(dry_run: bool = False):
    """Install post-commit hooks on git-backed compose folders → auto remember."""
    from .install_git_hooks import install_hooks

    results = install_hooks(dry_run=dry_run)
    installed = len([r for r in results if r.get("action") == "installed"])
    return {"installed": installed, "results": results}


@app.get("/api/projects/{project_key}/agent-brief")
async def get_agent_brief(project_key: str):
    """Agent landing page — distilled brief + one-line prompt."""
    project = hub.resolve_project_key(project_key)
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")
    try:
        payload = hub.get_agent_brief_payload(project_id=project["id"])
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return payload


@app.post("/api/projects/{project_id}/distill")
async def distill_one_project(project_id: int):
    """Regenerate AGENT_BRIEF.md for one project."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id FROM projects WHERE id = ?", (project_id,))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Project not found")
    spec_result = distill_spec(project_id)
    result = distill_project(project_id)
    result["spec"] = spec_result
    regenerate_index()
    return result


@app.get("/api/projects/{project_id}/agent-context")
async def get_project_agent_context(project_id: int):
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Project not found")
        project = dict(row)
        from .hub import _archived_session_count, _project_chats, _project_memories, _recent_archived_sessions

        chats = _project_chats(cur, project_id, 5)
        memories = _project_memories(cur, project_id, 30)
        archived_count = _archived_session_count(cur, project_id)
        archived_recent = _recent_archived_sessions(cur, project_id, 2)
    slug = project.get("slug") or f"project-{project_id}"
    md = read_project_md(slug) or ensure_project_md_from_db(project)
    ctx = build_project_agent_context(
        project, chats, memories, md,
        archived_session_count=archived_count,
        archived_recent_sessions=archived_recent,
    )
    ctx["paste_text"] = format_project_context_text(ctx)
    return ctx


@app.get("/api/index")
async def get_index(regenerate: bool = False):
    content = regenerate_index() if regenerate else read_index_md()
    return {"content": content}


@app.get("/api/onboarding")
async def get_onboarding():
    """Single setup doc for new devices and zero-context agents."""
    content = read_onboarding_md()
    public = os.environ.get("IDE_STORAGE_PUBLIC_URL", "http://127.0.0.1:6971").rstrip("/")
    return {
        "content": content,
        "web_url": f"{public}/?tab=setup",
        "host_path": os.environ.get(
            "IDE_STORAGE_COMPOSE_PATH",
            "/boot/config/plugins/compose.manager/projects/wolf-leader",
        )
        + "/data/ONBOARDING.md",
        "agent_prompt": (
            f"Connect this workspace to {PRODUCT_NAME}. "
            f"Fetch and follow: {public}/api/onboarding"
        ),
    }


@app.post("/api/memories")
async def create_memory(body: MemoryCreate):
    if body.type not in MEMORY_TYPES:
        raise HTTPException(status_code=400, detail=f"type must be one of {MEMORY_TYPES}")
    from .memory_ops import insert_memory, refresh_project_after_memory_change

    try:
        result = insert_memory(
            body.project_id,
            body.type,
            body.content,
            source_chat_id=body.source_chat_id,
            semantic_descriptor=body.semantic_descriptor,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if result.get("action") == "created":
        result["distill"] = refresh_project_after_memory_change(body.project_id)
    else:
        regenerate_index()
    return result


@app.get("/api/memories")
async def list_memories(
    project_id: Optional[int] = None,
    type: Optional[str] = None,
    limit: int = 100,
    include_superseded: bool = False,
):
    with db_conn() as conn:
        cur = conn.cursor()
        query = "SELECT * FROM memories WHERE 1=1"
        params = []
        if not include_superseded:
            query += " AND COALESCE(status, 'active') = 'active'"
        if project_id is not None:
            query += " AND project_id = ?"
            params.append(project_id)
        if type:
            query += " AND type = ?"
            params.append(type)
        query += " ORDER BY updated_at DESC LIMIT ?"
        params.append(limit)
        cur.execute(query, params)
        items = [dict(r) for r in cur.fetchall()]
    return {"memories": items, "count": len(items)}


@app.put("/api/memories/{memory_id}")
async def update_memory(memory_id: int, body: MemoryUpdate):
    if body.type is not None and body.type not in MEMORY_TYPES:
        raise HTTPException(status_code=400, detail=f"type must be one of {MEMORY_TYPES}")
    from .memory_ops import refresh_project_after_memory_change

    updates, params = [], []
    if body.type is not None:
        updates.append("type = ?")
        params.append(body.type)
    if body.content is not None:
        updates.append("content = ?")
        params.append(body.content)
    if body.semantic_descriptor is not None:
        updates.append("semantic_descriptor = ?")
        params.append(body.semantic_descriptor)
    if not updates:
        raise HTTPException(status_code=400, detail="No fields to update")
    updates.append("updated_at = ?")
    params.append(datetime.utcnow().isoformat())
    params.append(memory_id)
    project_id = None
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT project_id FROM memories WHERE id = ?", (memory_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Memory not found")
        project_id = row["project_id"]
        cur.execute(f"UPDATE memories SET {', '.join(updates)} WHERE id = ?", params)
        conn.commit()
    refresh_project_after_memory_change(project_id)
    from ide_storage.embed_index import sync_dirty

    sync_dirty(project_id=project_id, memory_ids=[memory_id])
    return {"message": "Memory updated", "project_id": project_id}


@app.delete("/api/memories/{memory_id}")
async def delete_memory(memory_id: int):
    from .memory_ops import refresh_project_after_memory_change

    project_id = None
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT project_id FROM memories WHERE id = ?", (memory_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Memory not found")
        project_id = row["project_id"]
        cur.execute("DELETE FROM memories WHERE id = ?", (memory_id,))
        conn.commit()
    refresh_project_after_memory_change(project_id)
    return {"message": "Memory deleted", "project_id": project_id}


# Snippet endpoints
@app.post("/api/snippets")
async def create_snippet(snippet: SnippetCreate):
    """Create a new code snippet."""
    now = datetime.utcnow().isoformat()
    tags_json = None
    if snippet.tags:
        import json
        tags_json = json.dumps(snippet.tags)
    
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO snippets (title, language, content, project_id, created_at, updated_at, tags)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (snippet.title, snippet.language, snippet.content, snippet.project_id, now, now, tags_json)
        )
        snippet_id = cur.lastrowid
        conn.commit()
    
    return {"id": snippet_id, "message": "Snippet created successfully"}


@app.get("/api/snippets")
async def list_snippets(
    project_id: Optional[int] = None,
    language: Optional[str] = None,
    limit: int = 100,
    offset: int = 0
):
    """List snippets with optional filtering."""
    with db_conn() as conn:
        cur = conn.cursor()
        
        query = "SELECT * FROM snippets WHERE 1=1"
        params = []
        
        if project_id:
            query += " AND project_id = ?"
            params.append(project_id)
        
        if language:
            query += " AND language = ?"
            params.append(language)
        
        query += " ORDER BY updated_at DESC LIMIT ? OFFSET ?"
        params.extend([limit, offset])
        
        cur.execute(query, params)
        rows = cur.fetchall()
        
        snippets = [dict(row) for row in rows]
        return {"snippets": snippets, "count": len(snippets)}


@app.get("/api/snippets/{snippet_id}")
async def get_snippet(snippet_id: int):
    """Get a specific snippet by ID."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM snippets WHERE id = ?", (snippet_id,))
        row = cur.fetchone()
        
        if not row:
            raise HTTPException(status_code=404, detail="Snippet not found")
        
        return dict(row)


@app.put("/api/snippets/{snippet_id}")
async def update_snippet(snippet_id: int, snippet: SnippetUpdate):
    """Update a snippet."""
    import json
    
    updates = []
    params = []
    
    if snippet.title is not None:
        updates.append("title = ?")
        params.append(snippet.title)
    
    if snippet.language is not None:
        updates.append("language = ?")
        params.append(snippet.language)
    
    if snippet.content is not None:
        updates.append("content = ?")
        params.append(snippet.content)
    
    if snippet.tags is not None:
        updates.append("tags = ?")
        params.append(json.dumps(snippet.tags))
    
    if not updates:
        raise HTTPException(status_code=400, detail="No fields to update")
    
    updates.append("updated_at = ?")
    params.append(datetime.utcnow().isoformat())
    params.append(snippet_id)
    
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            f"UPDATE snippets SET {', '.join(updates)} WHERE id = ?",
            params
        )
        conn.commit()
        
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Snippet not found")
    
    return {"message": "Snippet updated successfully"}


@app.delete("/api/snippets/{snippet_id}")
async def delete_snippet(snippet_id: int):
    """Delete a snippet."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM snippets WHERE id = ?", (snippet_id,))
        conn.commit()
        
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Snippet not found")
    
    return {"message": "Snippet deleted successfully"}


# Health check
@app.get("/health")
async def health():
    """Health check endpoint."""
    return {"status": "healthy", "service": SERVICE_ID, "product": PRODUCT_NAME}


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 6971))
    host = os.environ.get("HOST", "0.0.0.0")
    uvicorn.run(app, host=host, port=port)
