"""Files kept with a project: screenshots, mockups, PDFs.

Each file is stored on the hub next to the project's PROJECT.md (``<projects dir>/<slug>/attachments/``)
with a row in ``attachments`` for its caption and tags, so the app can show it and agents can find it.
"""
from __future__ import annotations

import base64
import json
import mimetypes
import os
import re
from datetime import datetime
from typing import Any

from ide_storage.db import db_conn, get_projects_dir

MAX_ATTACHMENT_BYTES = 15 * 1024 * 1024
_SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]+")


def _folder(slug: str) -> str:
    return os.path.join(get_projects_dir(), slug, "attachments")


def _clean_name(filename: str) -> str:
    base = os.path.basename((filename or "").replace("\\", "/")).strip()
    stem, ext = os.path.splitext(base)
    stem = _SAFE_NAME.sub("-", stem).strip("-.") or "file"
    ext = _SAFE_NAME.sub("", ext)[:10].lower()
    return f"{stem[:80]}{ext}"


def _row(r: dict[str, Any]) -> dict[str, Any]:
    out = dict(r)
    try:
        out["tags"] = json.loads(out.get("tags") or "[]")
    except (TypeError, json.JSONDecodeError):
        out["tags"] = []
    out["url"] = f"/api/attachments/{out['id']}"
    out.pop("path", None)
    return out


def _project_slug(cur, project_id: int) -> str:
    cur.execute("SELECT slug FROM projects WHERE id = ?", (project_id,))
    row = cur.fetchone()
    if not row:
        raise LookupError("project not found")
    return row["slug"] or str(project_id)


def add_attachment(
    project_id: int,
    filename: str,
    data: bytes,
    *,
    caption: str = "",
    tags: list[str] | None = None,
    chat_id: int | None = None,
) -> dict[str, Any]:
    if not data:
        raise ValueError("The file is empty")
    if len(data) > MAX_ATTACHMENT_BYTES:
        raise ValueError("Files can be at most 15 MB")
    name = _clean_name(filename)
    content_type = mimetypes.guess_type(name)[0] or "application/octet-stream"
    now = datetime.utcnow().isoformat()
    with db_conn() as conn:
        cur = conn.cursor()
        slug = _project_slug(cur, project_id)
        folder = _folder(slug)
        os.makedirs(folder, exist_ok=True)
        stem, ext = os.path.splitext(name)
        stored, n = name, 2
        while os.path.exists(os.path.join(folder, stored)):  # keep earlier files with the same name
            stored, n = f"{stem}-{n}{ext}", n + 1
        path = os.path.join(folder, stored)
        with open(path, "wb") as fh:
            fh.write(data)
        clean_tags = [t.strip() for t in tags or [] if t and t.strip()]
        cur.execute(
            """
            INSERT INTO attachments (project_id, filename, path, content_type, size_bytes, caption, tags, chat_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (project_id, stored, path, content_type, len(data), (caption or "").strip()[:500],
             json.dumps(clean_tags) if clean_tags else None, chat_id, now),
        )
        attachment_id = int(cur.lastrowid)
        conn.commit()
        cur.execute("SELECT * FROM attachments WHERE id = ?", (attachment_id,))
        return _row(dict(cur.fetchone()))


def add_attachment_base64(project_id: int, filename: str, content_base64: str, **kwargs: Any) -> dict[str, Any]:
    try:
        data = base64.b64decode(content_base64, validate=True)
    except (ValueError, TypeError) as exc:
        raise ValueError("content_base64 is not valid base64") from exc
    return add_attachment(project_id, filename, data, **kwargs)


def list_attachments(project_id: int, tag: str | None = None) -> list[dict[str, Any]]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM attachments WHERE project_id = ? ORDER BY created_at DESC, id DESC", (project_id,))
        rows = [_row(dict(r)) for r in cur.fetchall()]
    if tag:
        rows = [r for r in rows if tag in r["tags"]]
    return rows


def attachment_file(attachment_id: int) -> dict[str, Any] | None:
    """The stored row with its path on disk, for serving the file."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM attachments WHERE id = ?", (attachment_id,))
        row = cur.fetchone()
    return dict(row) if row else None


def update_attachment(attachment_id: int, *, caption: str | None = None, tags: list[str] | None = None) -> dict[str, Any]:
    with db_conn() as conn:
        cur = conn.cursor()
        if caption is not None:
            cur.execute("UPDATE attachments SET caption = ? WHERE id = ?", (caption.strip()[:500], attachment_id))
        if tags is not None:
            clean = [t.strip() for t in tags if t and t.strip()]
            cur.execute("UPDATE attachments SET tags = ? WHERE id = ?", (json.dumps(clean) if clean else None, attachment_id))
        conn.commit()
        cur.execute("SELECT * FROM attachments WHERE id = ?", (attachment_id,))
        row = cur.fetchone()
    if not row:
        raise LookupError("attachment not found")
    return _row(dict(row))


def delete_attachment(attachment_id: int) -> dict[str, Any]:
    row = attachment_file(attachment_id)
    if not row:
        raise LookupError("attachment not found")
    with db_conn() as conn:
        conn.cursor().execute("DELETE FROM attachments WHERE id = ?", (attachment_id,))
        conn.commit()
    try:
        os.remove(row["path"])
    except OSError:
        pass
    return {"ok": True, "deleted": attachment_id}
