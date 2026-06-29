"""Embedding index: build text, sync vectors, KNN lookup."""
from __future__ import annotations

import hashlib
import json
import sqlite3
from datetime import datetime
from typing import Any

from ide_storage.db import db_conn, load_vec_extension
from ide_storage.embeddings import (
    embed_dim,
    embed_model_name,
    embed_one,
    embed_texts,
    embeddings_available,
    serialize_vector,
)
from ide_storage.markdown_sync import read_project_md

EMBED_KINDS = ("memory", "project", "chat")


def text_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _project_semantic_descriptor(metadata: Any) -> str:
    if not metadata:
        return ""
    if isinstance(metadata, str):
        try:
            metadata = json.loads(metadata)
        except json.JSONDecodeError:
            return ""
    if isinstance(metadata, dict):
        return str(metadata.get("semantic_descriptor") or "").strip()
    return ""


def memory_embed_text(row: sqlite3.Row | dict[str, Any]) -> str:
    data = dict(row)
    parts: list[str] = []
    descriptor = (data.get("semantic_descriptor") or "").strip()
    if descriptor:
        parts.append(descriptor)
    typ = data.get("type") or "note"
    content = (data.get("content") or "").strip()
    parts.append(f"[{typ}] {content}")
    return "\n".join(parts).strip()


def project_embed_text(row: sqlite3.Row | dict[str, Any]) -> str:
    data = dict(row)
    parts: list[str] = []
    name = (data.get("name") or "").strip()
    slug = (data.get("slug") or "").strip()
    description = (data.get("description") or "").strip()
    if name:
        parts.append(name)
    if slug:
        parts.append(f"slug: {slug}")
    if description:
        parts.append(description)
    semantic = _project_semantic_descriptor(data.get("metadata"))
    if semantic:
        parts.append(semantic)
    if slug:
        md = read_project_md(slug)
        if md:
            parts.append(md[:4000])
    return "\n".join(parts).strip()


def chat_embed_text(row: sqlite3.Row | dict[str, Any]) -> str:
    data = dict(row)
    title = (data.get("title") or "").strip()
    content = (data.get("content") or "").strip()
    parts = [p for p in (title, content[:3000]) if p]
    return "\n".join(parts).strip()


def _upsert_embedding(
    cur: sqlite3.Cursor,
    *,
    kind: str,
    ref_id: int,
    embed_text: str,
    vector: list[float],
    now: str,
) -> None:
    model = embed_model_name()
    dim = embed_dim()
    th = text_hash(embed_text)
    blob = serialize_vector(vector)
    cur.execute(
        """
        INSERT INTO embeddings (kind, ref_id, model, dim, text_hash, embed_text, vector, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(kind, ref_id, model) DO UPDATE SET
            dim = excluded.dim,
            text_hash = excluded.text_hash,
            embed_text = excluded.embed_text,
            vector = excluded.vector,
            updated_at = excluded.updated_at
        """,
        (kind, ref_id, model, dim, th, embed_text, blob, now),
    )


def _existing_hashes(cur: sqlite3.Cursor, kind: str) -> dict[int, str]:
    model = embed_model_name()
    cur.execute(
        "SELECT ref_id, text_hash FROM embeddings WHERE kind = ? AND model = ?",
        (kind, model),
    )
    return {int(r[0]): r[1] for r in cur.fetchall()}


def sync_dirty(
    *,
    project_id: int | None = None,
    memory_ids: list[int] | None = None,
    chat_ids: list[int] | None = None,
) -> dict[str, Any]:
    """Re-embed rows whose source text changed or are missing from the index."""
    if not embeddings_available():
        return {"ok": True, "skipped": True, "reason": "embeddings unavailable"}

    now = datetime.utcnow().isoformat()
    report: dict[str, Any] = {"embedded": 0, "skipped_unchanged": 0, "kinds": {}}

    with db_conn() as conn:
        cur = conn.cursor()
        if not load_vec_extension(conn):
            return {"ok": False, "error": "sqlite-vec extension unavailable"}

        pending: list[tuple[str, int, str]] = []

        # Memories
        mem_query = """
            SELECT id, type, content, semantic_descriptor
            FROM memories
            WHERE COALESCE(status, 'active') = 'active'
        """
        mem_params: list[Any] = []
        if project_id is not None:
            mem_query += " AND project_id = ?"
            mem_params.append(project_id)
        if memory_ids:
            mem_query += f" AND id IN ({','.join('?' * len(memory_ids))})"
            mem_params.extend(memory_ids)
        cur.execute(mem_query, mem_params)
        mem_rows = cur.fetchall()
        mem_hashes = _existing_hashes(cur, "memory")
        for row in mem_rows:
            text = memory_embed_text(row)
            if not text:
                continue
            th = text_hash(text)
            if mem_hashes.get(row["id"]) == th:
                report["skipped_unchanged"] += 1
                continue
            pending.append(("memory", int(row["id"]), text))

        # Projects
        proj_query = "SELECT id, name, slug, description, metadata FROM projects WHERE 1=1"
        proj_params: list[Any] = []
        if project_id is not None:
            proj_query += " AND id = ?"
            proj_params.append(project_id)
        cur.execute(proj_query, proj_params)
        proj_rows = cur.fetchall()
        proj_hashes = _existing_hashes(cur, "project")
        for row in proj_rows:
            text = project_embed_text(row)
            if not text:
                continue
            th = text_hash(text)
            if proj_hashes.get(row["id"]) == th:
                report["skipped_unchanged"] += 1
                continue
            pending.append(("project", int(row["id"]), text))

        # Chats (optional, for semantic session search)
        if chat_ids or project_id is not None:
            chat_query = """
                SELECT id, title, content FROM chats
                WHERE COALESCE(status, 'active') = 'active'
            """
            chat_params: list[Any] = []
            if project_id is not None:
                chat_query += " AND project_id = ?"
                chat_params.append(project_id)
            if chat_ids:
                chat_query += f" AND id IN ({','.join('?' * len(chat_ids))})"
                chat_params.extend(chat_ids)
            cur.execute(chat_query, chat_params)
            chat_rows = cur.fetchall()
            chat_hashes = _existing_hashes(cur, "chat")
            for row in chat_rows:
                text = chat_embed_text(row)
                if not text:
                    continue
                th = text_hash(text)
                if chat_hashes.get(row["id"]) == th:
                    report["skipped_unchanged"] += 1
                    continue
                pending.append(("chat", int(row["id"]), text))

        if not pending:
            report["ok"] = True
            return report

        texts = [p[2] for p in pending]
        vectors = embed_texts(texts)
        if vectors is None:
            return {"ok": False, "error": "embedding model failed"}

        for (kind, ref_id, embed_text), vector in zip(pending, vectors):
            _upsert_embedding(
                cur, kind=kind, ref_id=ref_id, embed_text=embed_text, vector=vector, now=now
            )
            report["embedded"] += 1
            report["kinds"][kind] = report["kinds"].get(kind, 0) + 1

        conn.commit()

    report["ok"] = True
    return report


def knn(
    query_vector: list[float],
    *,
    kinds: tuple[str, ...] = ("memory", "project", "chat"),
    limit: int = 50,
    project_id: int | None = None,
) -> list[dict[str, Any]]:
    """Cosine-distance KNN over the embeddings table."""
    if not embeddings_available():
        return []

    blob = serialize_vector(query_vector)
    model = embed_model_name()
    placeholders = ",".join("?" * len(kinds))

    with db_conn() as conn:
        cur = conn.cursor()
        if not load_vec_extension(conn):
            return []

        sql = f"""
            SELECT e.kind, e.ref_id, e.embed_text,
                   vec_distance_cosine(e.vector, ?) AS distance
            FROM embeddings e
            WHERE e.model = ? AND e.kind IN ({placeholders})
        """
        params: list[Any] = [blob, model, *kinds]

        if project_id is not None and "memory" in kinds:
            sql += """
                AND (
                    e.kind != 'memory'
                    OR e.ref_id IN (
                        SELECT id FROM memories WHERE project_id = ? AND COALESCE(status, 'active') = 'active'
                    )
                )
            """
            params.append(project_id)

        sql += " ORDER BY distance ASC LIMIT ?"
        params.append(limit)

        cur.execute(sql, params)
        rows = [dict(r) for r in cur.fetchall()]

    return _hydrate_knn_rows(rows)


def _hydrate_knn_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not rows:
        return []

    out: list[dict[str, Any]] = []
    with db_conn() as conn:
        cur = conn.cursor()
        for row in rows:
            kind = row["kind"]
            ref_id = int(row["ref_id"])
            distance = float(row["distance"])
            similarity = max(0.0, 1.0 - distance)
            item: dict[str, Any] = {
                "kind": kind,
                "id": ref_id,
                "distance": distance,
                "similarity": similarity,
                "source": "vector",
            }
            if kind == "memory":
                cur.execute(
                    """
                    SELECT id, type, content, project_id
                    FROM memories
                    WHERE id = ? AND COALESCE(status, 'active') = 'active'
                    """,
                    (ref_id,),
                )
                mem = cur.fetchone()
                if not mem:
                    continue
                mem = dict(mem)
                item.update(
                    {
                        "title": f"[{mem['type']}] {mem['content'][:120]}",
                        "content": mem["content"],
                        "project_id": mem["project_id"],
                        "memory_type": mem["type"],
                    }
                )
            elif kind == "project":
                cur.execute(
                    "SELECT id, name, slug, description FROM projects WHERE id = ?",
                    (ref_id,),
                )
                proj = cur.fetchone()
                if not proj:
                    continue
                proj = dict(proj)
                item.update(
                    {
                        "title": proj["name"],
                        "content": proj.get("description"),
                        "slug": proj.get("slug"),
                    }
                )
            elif kind == "chat":
                cur.execute(
                    "SELECT id, title, substr(content, 1, 200) AS content, updated_at FROM chats WHERE id = ?",
                    (ref_id,),
                )
                chat = cur.fetchone()
                if not chat:
                    continue
                chat = dict(chat)
                item.update(
                    {
                        "title": chat.get("title"),
                        "content": chat.get("content"),
                        "updated_at": chat.get("updated_at"),
                    }
                )
            else:
                continue
            out.append(item)
    return out


def project_vector_similarities(query_text: str) -> dict[int, float]:
    """Return project_id -> similarity for routing tie-breaks."""
    if not embeddings_available():
        return {}
    query_vec = embed_one(query_text)
    if not query_vec:
        return {}

    hits = knn(query_vec, kinds=("project",), limit=20)
    return {int(h["id"]): float(h.get("similarity") or 0.0) for h in hits}
