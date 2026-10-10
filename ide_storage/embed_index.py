"""Embedding index: build text, sync vectors, KNN lookup (pgvector)."""
from __future__ import annotations

import hashlib
import json
from datetime import datetime
from typing import Any

from ide_storage import localtime as LT
from ide_storage.db import db_conn
from ide_storage.embeddings import (
    embed_dim,
    embed_model_name,
    embed_one,
    embed_texts,
    embeddings_available,
)
from ide_storage.markdown_sync import read_project_md

# Row kinds that carry a vector. "howl", "catalog" and "chunk" are the
# broadcast note, the filesystem catalog blurb and an ingested file slice.
EMBED_KINDS = ("memory", "project", "chat", "howl", "catalog", "chunk")
CORE_KINDS = ("memory", "project", "chat")

# Sub-batch size for embedding so a large project doesn't spike RAM/CPU by
# embedding everything in one call. Mirrors backfill_embeddings.DEFAULT_BATCH.
DEFAULT_BATCH = 20


def text_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def synthesize_descriptor(
    *,
    kind: str,
    type: str | None = None,
    content: str,
    project_name: str | None = None,
    slug: str | None = None,
) -> str:
    """Cheap, LLM-free fallback semantic descriptor from available fields.

    Used server-side so the vector index is never silently content-only when an
    agent forgets to supply a descriptor. Pure string composition — keep it cheap.
    """
    content = (content or "").strip()
    snippet = content[:200].strip()
    label = (project_name or slug or "").strip()

    # With no usable content, the best we can offer is the project label (or
    # nothing) — a bare "memory:"/"project:" prefix carries no signal.
    if not snippet:
        return label

    prefix_bits: list[str] = []
    if label:
        prefix_bits.append(label)
    type_part = (type or kind or "").strip()
    if type_part:
        prefix_bits.append(f"{type_part}:")
    prefix = " ".join(prefix_bits).strip()
    return f"{prefix} {snippet}".strip() if prefix else snippet


def delete_embeddings(pairs: list[tuple[str, int]]) -> int:
    """Delete embedding rows for (kind, ref_id) pairs. Safe no-op if none.

    Not gated on embeddings being enabled: the embeddings table always exists and
    may hold rows from a period when embeddings were on, so stale rows must be
    cleaned up regardless of the current toggle.
    """
    pairs = [(k, int(r)) for k, r in (pairs or []) if k and r is not None]
    if not pairs:
        return 0
    deleted = 0
    try:
        with db_conn() as conn:
            cur = conn.cursor()
            for kind, ref_id in pairs:
                cur.execute(
                    "DELETE FROM embeddings WHERE kind = ? AND ref_id = ?",
                    (kind, ref_id),
                )
                deleted += cur.rowcount
            conn.commit()
    except Exception:
        return deleted
    return deleted


def delete_project_embeddings(project_id: int) -> int:
    """Delete embeddings for a project and all rows that hang off it."""
    tables = {
        "memory": "memories",
        "chat": "chats",
        "howl": "howls",
        "catalog": "fs_catalog",
        "chunk": "file_chunks",
    }
    pairs: list[tuple[str, int]] = [("project", int(project_id))]
    try:
        with db_conn() as conn:
            cur = conn.cursor()
            for kind, table in tables.items():
                cur.execute(f"SELECT id FROM {table} WHERE project_id = ?", (project_id,))
                pairs += [(kind, int(r[0])) for r in cur.fetchall()]
    except Exception:
        return 0
    return delete_embeddings(pairs)


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


def howl_embed_text(row: Any) -> str:
    data = dict(row)
    parts: list[str] = []
    project_name = (data.get("project_name") or data.get("project_slug") or "").strip()
    if project_name:
        parts.append(f"Project: {project_name}")
    summary = (data.get("summary") or "").strip()
    if summary:
        parts.append(summary[:3000])
    return "\n".join(parts).strip()


def catalog_embed_text(row: Any) -> str:
    data = dict(row)
    parts: list[str] = []
    project_name = (data.get("project_name") or data.get("project_slug") or "").strip()
    if project_name:
        parts.append(f"Project: {project_name}")
    parts.append(f"File: {data.get('rel_path') or data.get('name') or ''}")
    blurb = (data.get("blurb") or "").strip()
    if blurb:
        parts.append(blurb[:600])
    return "\n".join(parts).strip()


def chunk_embed_text(row: Any) -> str:
    data = dict(row)
    path = (data.get("path") or "").strip()
    content = (data.get("content") or "").strip()
    return f"{path}\n{content[:3000]}".strip()


def memory_embed_text(row: Any) -> str:
    data = dict(row)
    parts: list[str] = []
    # Project context anchors the vector so memories from different projects
    # don't collapse into undifferentiated soup.
    project_name = (data.get("project_name") or "").strip()
    project_slug = (data.get("project_slug") or "").strip()
    if project_name:
        parts.append(f"Project: {project_name}")
    elif project_slug:
        parts.append(f"Project: {project_slug}")
    descriptor = (data.get("semantic_descriptor") or "").strip()
    if descriptor:
        parts.append(descriptor)
    typ = data.get("type") or "note"
    content = (data.get("content") or "").strip()
    parts.append(f"[{typ}] {content}")
    return "\n".join(parts).strip()


def project_embed_text(row: Any) -> str:
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


def chat_embed_text(row: Any) -> str:
    data = dict(row)
    title = (data.get("title") or "").strip()
    content = (data.get("content") or "").strip()
    parts = [p for p in (title, content[:3000]) if p]
    return "\n".join(parts).strip()


def vector_literal(vector: list[float]) -> str:
    """pgvector text form: '[0.1,0.2,...]'."""
    return "[" + ",".join(f"{float(v):.8g}" for v in vector) + "]"


def _upsert_embedding(
    cur,
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
    cur.execute(
        """
        INSERT INTO embeddings (kind, ref_id, model, dim, text_hash, embed_text, vector, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?::vector, ?)
        ON CONFLICT(kind, ref_id, model) DO UPDATE SET
            dim = excluded.dim,
            text_hash = excluded.text_hash,
            embed_text = excluded.embed_text,
            vector = excluded.vector,
            updated_at = excluded.updated_at
        """,
        (kind, ref_id, model, dim, th, embed_text, vector_literal(vector), now),
    )


def _existing_hashes(cur, kind: str) -> dict[int, str]:
    model = embed_model_name()
    cur.execute(
        "SELECT ref_id, text_hash FROM embeddings WHERE kind = ? AND model = ?",
        (kind, model),
    )
    return {int(r[0]): r[1] for r in cur.fetchall()}


def _collect(pending, report, rows, kind, hashes, text_fn) -> None:
    for row in rows:
        text = text_fn(row)
        if not text:
            continue
        th = text_hash(text)
        if hashes.get(int(row["id"])) == th:
            report["skipped_unchanged"] += 1
            continue
        pending.append((kind, int(row["id"]), text))


def sync_dirty(
    *,
    project_id: int | None = None,
    memory_ids: list[int] | None = None,
    chat_ids: list[int] | None = None,
    howl_ids: list[int] | None = None,
    catalog_ids: list[int] | None = None,
    chunk_ids: list[int] | None = None,
) -> dict[str, Any]:
    """Re-embed rows whose source text changed or are missing from the index.

    This is the embed-on-write path: every save/howl/catalog refresh calls it for
    the rows it just touched.
    """
    if not embeddings_available():
        return {"ok": True, "skipped": True, "reason": "embeddings unavailable"}

    now = datetime.utcnow().isoformat()
    report: dict[str, Any] = {"embedded": 0, "skipped_unchanged": 0, "kinds": {}}

    # --- Phase 1: open a read connection, collect pending work, then CLOSE it. --
    # We deliberately do NOT hold a DB connection open while embedding (which can
    # be slow on CPU) so writers aren't blocked the whole time.
    pending: list[tuple[str, int, str]] = []
    with db_conn() as conn:
        cur = conn.cursor()

        # Memories — JOIN projects so embed text includes project name for better clustering
        mem_query = """
            SELECT m.id, m.type, m.content, m.semantic_descriptor,
                   p.name AS project_name, p.slug AS project_slug
            FROM memories m
            LEFT JOIN projects p ON p.id = m.project_id
            WHERE COALESCE(m.status, 'active') = 'active'
        """
        mem_params: list[Any] = []
        if project_id is not None:
            mem_query += " AND m.project_id = ?"
            mem_params.append(project_id)
        if memory_ids:
            mem_query += f" AND m.id IN ({','.join('?' * len(memory_ids))})"
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
            # Every saved chat gets a vector, archived included: the save pipeline
            # archives before it embeds, and _hydrate_knn_rows applies the
            # active/archived visibility rule at query time.
            chat_query = "SELECT id, title, content FROM chats WHERE 1=1"
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

        # Howls
        if howl_ids or project_id is not None:
            q = """
                SELECT h.id, h.summary, p.name AS project_name, p.slug AS project_slug
                FROM howls h LEFT JOIN projects p ON p.id = h.project_id WHERE 1=1
            """
            params: list[Any] = []
            if project_id is not None:
                q += " AND h.project_id = ?"
                params.append(project_id)
            if howl_ids:
                q += f" AND h.id IN ({','.join('?' * len(howl_ids))})"
                params.extend(howl_ids)
            cur.execute(q, params)
            _collect(pending, report, cur.fetchall(), "howl", _existing_hashes(cur, "howl"), howl_embed_text)

        # Filesystem catalog (only explicit ids or a project refresh)
        if catalog_ids or project_id is not None:
            q = """
                SELECT f.id, f.rel_path, f.name, f.blurb, p.name AS project_name, p.slug AS project_slug
                FROM fs_catalog f LEFT JOIN projects p ON p.id = f.project_id
                WHERE f.is_dir = FALSE
            """
            params = []
            if project_id is not None:
                q += " AND f.project_id = ?"
                params.append(project_id)
            if catalog_ids:
                q += f" AND f.id IN ({','.join('?' * len(catalog_ids))})"
                params.extend(catalog_ids)
            cur.execute(q, params)
            _collect(pending, report, cur.fetchall(), "catalog", _existing_hashes(cur, "catalog"), catalog_embed_text)

        # File chunks
        if chunk_ids or project_id is not None:
            q = "SELECT id, path, content FROM file_chunks WHERE 1=1"
            params = []
            if project_id is not None:
                q += " AND project_id = ?"
                params.append(project_id)
            if chunk_ids:
                q += f" AND id IN ({','.join('?' * len(chunk_ids))})"
                params.extend(chunk_ids)
            cur.execute(q, params)
            _collect(pending, report, cur.fetchall(), "chunk", _existing_hashes(cur, "chunk"), chunk_embed_text)

    if not pending:
        report["ok"] = True
        return report

    # --- Phase 2: embed OUTSIDE any DB transaction, in bounded sub-batches. -----
    # Each batch is embedded then written in its own short write connection so a
    # large project never spikes RAM/CPU in one call and writers aren't starved.
    for batch_start in range(0, len(pending), DEFAULT_BATCH):
        batch = pending[batch_start : batch_start + DEFAULT_BATCH]
        texts = [p[2] for p in batch]
        vectors = embed_texts(texts)
        if vectors is None:
            return {"ok": False, "error": "embedding model failed", **report}
        if len(vectors) != len(texts):
            return {
                "ok": False,
                "error": (
                    f"embedding alignment mismatch: {len(vectors)} vectors "
                    f"for {len(texts)} texts"
                ),
                **report,
            }

        # --- Phase 3: short write connection for this batch's upserts. ----------
        with db_conn() as conn:
            cur = conn.cursor()
            for (kind, ref_id, embed_text), vector in zip(batch, vectors):
                _upsert_embedding(
                    cur, kind=kind, ref_id=ref_id, embed_text=embed_text, vector=vector, now=now
                )
                report["embedded"] += 1
                report["kinds"][kind] = report["kinds"].get(kind, 0) + 1
            conn.commit()

    report["ok"] = True
    return report


MIN_SIMILARITY = 0.25  # cosine distance > 0.75 → noise, discard


def knn(
    query_vector: list[float],
    *,
    kinds: tuple[str, ...] = ("memory", "project", "chat"),
    limit: int = 50,
    project_id: int | None = None,
    min_similarity: float = MIN_SIMILARITY,
    include_archived: bool = False,
) -> list[dict[str, Any]]:
    """Cosine-distance KNN over the embeddings table (pgvector ``<=>``)."""
    if not embeddings_available():
        return []

    qvec = vector_literal(query_vector)
    model = embed_model_name()
    placeholders = ",".join("?" * len(kinds))

    with db_conn() as conn:
        cur = conn.cursor()
        sql = f"""
            SELECT e.kind, e.ref_id, e.embed_text,
                   (e.vector <=> ?::vector) AS distance
            FROM embeddings e
            WHERE e.model = ? AND e.kind IN ({placeholders})
        """
        params: list[Any] = [qvec, model, *kinds]

        if project_id is not None:
            sql += """
                AND (
                    (e.kind = 'memory' AND e.ref_id IN (
                        SELECT id FROM memories WHERE project_id = ? AND COALESCE(status, 'active') = 'active'))
                 OR (e.kind = 'chat' AND e.ref_id IN (SELECT id FROM chats WHERE project_id = ?))
                 OR (e.kind = 'howl' AND e.ref_id IN (SELECT id FROM howls WHERE project_id = ?))
                 OR (e.kind = 'catalog' AND e.ref_id IN (SELECT id FROM fs_catalog WHERE project_id = ?))
                 OR (e.kind = 'chunk' AND e.ref_id IN (SELECT id FROM file_chunks WHERE project_id = ?))
                 OR (e.kind = 'project' AND e.ref_id = ?)
                )
            """
            params.extend([project_id] * 6)

        max_distance = 1.0 - min_similarity
        sql += " AND (e.vector <=> ?::vector) <= ? ORDER BY distance ASC LIMIT ?"
        params.extend([qvec, max_distance, limit])

        cur.execute(sql, params)
        rows = [dict(r) for r in cur.fetchall()]

    return _hydrate_knn_rows(rows, include_archived=include_archived)


def neighbors_for(
    kind: str,
    ref_id: int,
    *,
    kinds: tuple[str, ...] = ("project", "memory", "howl", "chat"),
    limit: int = 8,
    min_similarity: float = 0.35,
) -> list[dict[str, Any]]:
    """Nearest rows to an already-embedded row (used for vault "Related" links)."""
    if not embeddings_available():
        return []
    model = embed_model_name()
    placeholders = ",".join("?" * len(kinds))
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            f"""
            SELECT e.kind, e.ref_id, e.embed_text,
                   (e.vector <=> src.vector) AS distance
            FROM embeddings e,
                 (SELECT vector FROM embeddings WHERE kind = ? AND ref_id = ? AND model = ?) src
            WHERE e.model = ? AND e.kind IN ({placeholders})
              AND NOT (e.kind = ? AND e.ref_id = ?)
              AND (e.vector <=> src.vector) <= ?
            ORDER BY distance ASC LIMIT ?
            """,
            [kind, ref_id, model, model, *kinds, kind, ref_id, 1.0 - min_similarity, limit],
        )
        rows = [dict(r) for r in cur.fetchall()]
    return _hydrate_knn_rows(rows, include_archived=True)


def _hydrate_knn_rows(
    rows: list[dict[str, Any]], *, include_archived: bool = False
) -> list[dict[str, Any]]:
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
                # Mirror the keyword leg: exclude non-active (archived) chats from
                # vector results unless the caller explicitly wants archived too,
                # so both search legs agree on what's visible.
                if include_archived:
                    cur.execute(
                        "SELECT id, title, substr(content, 1, 200) AS content, updated_at FROM chats WHERE id = ?",
                        (ref_id,),
                    )
                else:
                    cur.execute(
                        """
                        SELECT id, title, substr(content, 1, 200) AS content, updated_at
                        FROM chats
                        WHERE id = ? AND COALESCE(status, 'active') = 'active'
                        """,
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
            elif kind == "howl":
                cur.execute(
                    """
                    SELECT h.id, h.project_id, h.summary, h.created_at, h.git_commit,
                           p.slug AS project_slug
                    FROM howls h LEFT JOIN projects p ON p.id = h.project_id
                    WHERE h.id = ?
                    """,
                    (ref_id,),
                )
                howl = cur.fetchone()
                if not howl:
                    continue
                howl = dict(howl)
                item.update(
                    {
                        "title": f"Howl {LT.fmt(howl['created_at'])} · {howl.get('project_slug') or ''}".strip(" ·"),
                        "content": (howl.get("summary") or "")[:300],
                        "project_id": howl.get("project_id"),
                        "slug": howl.get("project_slug"),
                        "created_at": howl.get("created_at"),
                        "stamp": LT.stamp(howl.get("created_at")),
                    }
                )
            elif kind == "catalog":
                cur.execute(
                    "SELECT id, project_id, root_path, rel_path, name, blurb, mtime FROM fs_catalog WHERE id = ?",
                    (ref_id,),
                )
                cat = cur.fetchone()
                if not cat:
                    continue
                cat = dict(cat)
                item.update(
                    {
                        "title": cat["rel_path"],
                        "content": cat.get("blurb"),
                        "project_id": cat.get("project_id"),
                        "path": f"{cat['root_path'].rstrip('/')}/{cat['rel_path']}",
                        "mtime": cat.get("mtime"),
                    }
                )
            elif kind == "chunk":
                cur.execute(
                    "SELECT id, project_id, path, chunk_index, content FROM file_chunks WHERE id = ?",
                    (ref_id,),
                )
                ch = cur.fetchone()
                if not ch:
                    continue
                ch = dict(ch)
                item.update(
                    {
                        "title": f"{ch['path']} #{ch['chunk_index']}",
                        "content": (ch.get("content") or "")[:400],
                        "project_id": ch.get("project_id"),
                        "path": ch["path"],
                        "chunk_index": ch["chunk_index"],
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

    hits = knn(query_vec, kinds=("project",), limit=20, min_similarity=0.20)
    return {int(h["id"]): float(h.get("similarity") or 0.0) for h in hits}
