"""Chats made in the Wolf Leader app, kept whole on the hub so every device has them.

The app also saves each chat with save_session (that feeds memories, search and the brief).
This store holds the app's own record of the chat — agent, mode, project, every step — so a
chat started on one Mac opens and continues on another exactly as it was.

Devices push a chat after each change and pull everything changed since their last pull.
The newer copy (by the record's own `updated` time) wins; a deleted chat leaves a tombstone so
other devices drop it too.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from ide_storage.db import db_conn

router = APIRouter(prefix="/api/app-chats", tags=["app-chats"])

# A pull asks for "changed since T"; looking back a little covers writes that landed while the
# previous pull was being answered. The app ignores copies it already has.
_OVERLAP = timedelta(seconds=5)


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _row(row) -> Dict[str, Any]:
    raw = row["record"]
    try:
        record = json.loads(raw) if raw else None
    except (TypeError, ValueError):
        record = None
    return {
        "id": row["id"],
        "updated": row["updated"],
        "server_updated": row["server_updated"],
        "device": row["device"],
        "deleted": bool(row["deleted"]),
        "record": record,
    }


class PutBody(BaseModel):
    record: Dict[str, Any]
    # ISO-8601 UTC with milliseconds, e.g. 2026-11-05T19:08:32.123Z: when the record last changed.
    updated: str = Field(min_length=10, max_length=40)
    device: Optional[str] = None
    project_id: Optional[int] = None
    title: Optional[str] = None
    agent_id: Optional[str] = None


@router.get("")
def list_app_chats(since: Optional[str] = None, limit: int = 500, include_deleted: bool = True) -> Dict[str, Any]:
    """Chats changed since `since` (the `now` from the previous pull), newest first. No `since` = all."""
    limit = max(1, min(limit, 2000))
    started = _now()
    query = "SELECT id, record, updated, server_updated, device, deleted FROM app_chats WHERE 1=1"
    params: list[Any] = []
    if since:
        try:
            cutoff = datetime.strptime(since.replace("Z", ""), "%Y-%m-%dT%H:%M:%S.%f") - _OVERLAP
        except ValueError:
            raise HTTPException(400, "since must be the `now` value from a previous pull")
        query += " AND server_updated > ?"
        params.append(cutoff.strftime("%Y-%m-%dT%H:%M:%S.%fZ"))
    if not include_deleted:
        query += " AND deleted = 0"
    query += " ORDER BY server_updated DESC LIMIT ?"
    params.append(limit)
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(query, params)
        rows = [_row(r) for r in cur.fetchall()]
    return {"chats": rows, "count": len(rows), "now": started}


@router.get("/{chat_id}")
def get_app_chat(chat_id: str) -> Dict[str, Any]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, record, updated, server_updated, device, deleted FROM app_chats WHERE id = ?",
            (chat_id,),
        )
        row = cur.fetchone()
    if not row:
        raise HTTPException(404, "No such chat")
    return _row(row)


@router.put("/{chat_id}")
def put_app_chat(chat_id: str, body: PutBody) -> Dict[str, Any]:
    """Store this device's copy unless the hub already has a newer one (then 409 with that copy)."""
    if len(chat_id) > 80:
        raise HTTPException(400, "chat id too long")
    now = _now()
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, record, updated, server_updated, device, deleted FROM app_chats WHERE id = ?",
            (chat_id,),
        )
        row = cur.fetchone()
        if row and (row["updated"] or "") > body.updated:
            existing = _row(row)
            raise HTTPException(409, detail={"error": "The hub has a newer copy of this chat.", "chat": existing})
        cur.execute(
            """
            INSERT INTO app_chats (id, record, updated, server_updated, device, project_id, title, agent_id, deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT (id) DO UPDATE SET
                record = excluded.record,
                updated = excluded.updated,
                server_updated = excluded.server_updated,
                device = excluded.device,
                project_id = excluded.project_id,
                title = excluded.title,
                agent_id = excluded.agent_id,
                deleted = 0
            """,
            (
                chat_id,
                json.dumps(body.record, ensure_ascii=False),
                body.updated,
                now,
                body.device,
                body.project_id,
                (body.title or "")[:300],
                body.agent_id,
            ),
        )
        conn.commit()
    return {"ok": True, "id": chat_id, "server_updated": now}


# ---------------------------------------------------------------- rules for every chat
# One set of rules for every chat, every agent, every device: whether agents may act without
# asking, what new chats start in, instructions every agent gets, and which skills from the
# hub's library every chat starts with.

rules_router = APIRouter(prefix="/api/chat-rules", tags=["app-chats"])
_RULES_KEY = "chat_rules"
_DEFAULT_SKIP = {"wolfhowl", "wolfeat"}  # saving and recall happen on their own in the app


class ChatRules(BaseModel):
    never_ask: bool = True
    default_mode: str = Field(default="auto", pattern="^(ask|edits|auto)$")
    rules: str = Field(default="", max_length=20000)
    # None = not chosen yet: every skill except wolfhowl/wolfeat.
    skills: Optional[list[str]] = None


def _read_rules() -> Dict[str, Any]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT value, updated_at FROM app_settings WHERE key = ?", (_RULES_KEY,))
        row = cur.fetchone()
    saved: Dict[str, Any] = {}
    if row:
        try:
            saved = json.loads(row["value"]) or {}
        except (TypeError, ValueError):
            saved = {}
    rules = ChatRules(**{k: v for k, v in saved.items() if k in ChatRules.model_fields}).model_dump()
    from ide_storage.skill_registry import list_skills

    library = [s["name"] for s in list_skills()]
    if rules["skills"] is None:
        rules["skills"] = [n for n in library if n not in _DEFAULT_SKIP]
    rules["skills"] = [n for n in rules["skills"] if n in library]
    rules["library"] = library
    rules["updated_at"] = row["updated_at"] if row else None
    return rules


@rules_router.get("")
def get_chat_rules() -> Dict[str, Any]:
    return _read_rules()


@rules_router.put("")
def put_chat_rules(body: ChatRules) -> Dict[str, Any]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO app_settings (key, value, updated_at) VALUES (?, ?, ?)
            ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """,
            (_RULES_KEY, json.dumps(body.model_dump()), _now()),
        )
        conn.commit()
    return _read_rules()


@router.delete("/{chat_id}")
def delete_app_chat(chat_id: str, device: Optional[str] = None) -> Dict[str, Any]:
    """Leave a tombstone so every device removes the chat. The save_session copy stays in the project."""
    now = _now()
    # Same shape the app sends (milliseconds), so "which is newer" compares like with like.
    updated = now[:23] + "Z"
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO app_chats (id, record, updated, server_updated, device, deleted)
            VALUES (?, NULL, ?, ?, ?, 1)
            ON CONFLICT (id) DO UPDATE SET
                record = NULL, updated = excluded.updated, server_updated = excluded.server_updated,
                device = excluded.device, deleted = 1
            """,
            (chat_id, updated, now, device),
        )
        conn.commit()
    return {"ok": True, "id": chat_id, "deleted": True}
