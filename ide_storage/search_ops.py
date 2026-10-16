"""Hybrid keyword + vector search with reciprocal rank fusion."""
from __future__ import annotations

from typing import Any

from ide_storage import localtime as LT
from ide_storage.conversation_search import (
    enrich_hits,
    filter_hits_by_scope,
    fuzzy_search,
    has_scope,
)
from ide_storage.db import db_conn
from ide_storage.embed_index import knn
from ide_storage.embeddings import embed_one, embeddings_available

RRF_K = 60
# Vector results get 1.5x weight so semantic matches can surface over
# pure substring hits when the query is clearly a description, not a keyword.
VECTOR_WEIGHT = 1.5


def result_key(item: dict[str, Any]) -> str:
    kind = item.get("kind") or "unknown"
    item_id = item.get("id")
    if kind == "message":
        chat_id = item.get("chat_id")
        return f"message:{item_id}:{chat_id}"
    return f"{kind}:{item_id}"


def reciprocal_rank_fusion(
    keyword_results: list[dict[str, Any]],
    vector_results: list[dict[str, Any]],
    *,
    k: int = RRF_K,
    vector_weight: float = VECTOR_WEIGHT,
) -> list[dict[str, Any]]:
    scores: dict[str, float] = {}
    items: dict[str, dict[str, Any]] = {}

    for rank, item in enumerate(keyword_results):
        key = result_key(item)
        scores[key] = scores.get(key, 0.0) + 1.0 / (k + rank + 1)
        if key not in items:
            items[key] = dict(item)

    for rank, item in enumerate(vector_results):
        key = result_key(item)
        scores[key] = scores.get(key, 0.0) + vector_weight / (k + rank + 1)
        if key not in items:
            items[key] = dict(item)

    merged = []
    for key, score in sorted(scores.items(), key=lambda x: x[1], reverse=True):
        row = dict(items[key])
        row["rank"] = score
        row["rrf_score"] = score
        merged.append(row)
    return merged


ALL_KINDS = frozenset({"memory", "project", "chat", "message", "howl", "catalog", "chunk"})
VECTOR_KINDS = ("memory", "project", "chat", "howl", "catalog", "chunk", "convo")


def _parse_kinds(kinds_param: str | None) -> frozenset[str] | None:
    """Return a frozenset of requested kinds, or None meaning all kinds."""
    if not kinds_param:
        return None
    parsed = frozenset(k.strip() for k in kinds_param.split(",") if k.strip() in ALL_KINDS)
    return parsed if parsed else None


def _all_words_clause(query: str, columns: list[str]) -> tuple[str, list[str]]:
    """SQL that matches when every word of ``query`` appears in one of ``columns``.

    Word order does not matter, so "lid display" finds "display ... lid". A
    single word behaves exactly like the old one-pattern LIKE.
    """
    words = query.split() or [query]
    clauses: list[str] = []
    params: list[str] = []
    for word in words:
        pattern = f"%{word}%"
        clauses.append("(" + " OR ".join(f"{col} LIKE ?" for col in columns) + ")")
        params.extend([pattern] * len(columns))
    return " AND ".join(clauses), params


def keyword_search(
    query: str,
    *,
    limit: int = 50,
    include_archived: bool = False,
    hub_mode: bool = False,
    kinds: frozenset[str] | None = None,
) -> list[dict[str, Any]]:
    pattern = f"%{query}%"
    results: list[dict[str, Any]] = []
    chat_filter = "" if include_archived else " AND COALESCE(c.status, 'active') = 'active'"
    want = kinds or ALL_KINDS
    mem_where, mem_params = _all_words_clause(
        query, ["m.content", "COALESCE(m.semantic_descriptor, '')"]
    )

    with db_conn() as conn:
        cur = conn.cursor()

        if "memory" in want:
            cur.execute(
                f"""
                SELECT m.id, printf('[%s] %s', m.type, substr(m.content, 1, 120)) AS title,
                       m.content, m.project_id, m.created_at, 'memory' AS kind, m.type AS memory_type
                FROM memories m
                WHERE {mem_where}
                  AND COALESCE(m.status, 'active') = 'active'
                ORDER BY m.updated_at DESC LIMIT ?
                """,
                (*mem_params, limit),
            )
            for row in cur.fetchall():
                item = dict(row)
                item["source"] = "keyword"
                results.append(item)

        if "project" in want:
            if hub_mode:
                cur.execute(
                    """
                    SELECT p.id, p.name AS title, 'project' AS kind
                    FROM projects p
                    WHERE p.name LIKE ? OR p.slug LIKE ? LIMIT ?
                    """,
                    (pattern, pattern, limit),
                )
            else:
                cur.execute(
                    """
                    SELECT p.id, p.name AS title, p.description AS content, p.slug,
                           'project' AS kind
                    FROM projects p
                    WHERE p.name LIKE ? OR p.slug LIKE ? OR p.description LIKE ?
                       OR COALESCE(p.metadata, '') LIKE ?
                    ORDER BY p.updated_at DESC LIMIT ?
                    """,
                    (pattern, pattern, pattern, pattern, limit),
                )
            for row in cur.fetchall():
                item = dict(row)
                item["source"] = "keyword"
                results.append(item)

        if "chat" in want:
            title_len = 80 if hub_mode else 200
            chat_where, chat_params = _all_words_clause(query, ["c.title", "c.content"])
            cur.execute(
                f"""
                SELECT c.id, c.title, substr(c.content, 1, {title_len}) AS content,
                       c.updated_at, 'chat' AS kind
                FROM chats c
                WHERE {chat_where}{chat_filter}
                ORDER BY c.updated_at DESC LIMIT ?
                """,
                (*chat_params, limit),
            )
            for row in cur.fetchall():
                item = dict(row)
                item["source"] = "keyword"
                results.append(item)

        if "message" in want and not hub_mode:
            msg_where, msg_params = _all_words_clause(query, ["m.content"])
            cur.execute(
                f"""
                SELECT m.id, m.chat_id, m.role, substr(m.content, 1, 200) AS content,
                       m.created_at, c.title AS chat_title, 'message' AS kind
                FROM messages m
                JOIN chats c ON c.id = m.chat_id
                WHERE {msg_where}{chat_filter}
                ORDER BY m.created_at DESC LIMIT ?
                """,
                (*msg_params, limit),
            )
            for row in cur.fetchall():
                item = dict(row)
                item["source"] = "keyword"
                results.append(item)

        if "howl" in want:
            howl_where, howl_params = _all_words_clause(query, ["h.summary", "COALESCE(h.actions, '')"])
            cur.execute(
                f"""
                SELECT h.id, h.project_id, substr(h.summary, 1, 200) AS content,
                       h.created_at, h.git_commit, p.slug AS slug,
                       'howl' AS kind
                FROM howls h LEFT JOIN projects p ON p.id = h.project_id
                WHERE {howl_where}
                ORDER BY h.created_at DESC LIMIT ?
                """,
                (*howl_params, limit),
            )
            for row in cur.fetchall():
                item = dict(row)
                item["title"] = f"Howl {LT.fmt(item.get('created_at'))} · {item.get('slug') or ''}".strip(" ·")
                item["stamp"] = LT.stamp(item.get("created_at"))
                item["source"] = "keyword"
                results.append(item)

        if "catalog" in want:
            cur.execute(
                """
                SELECT f.id, f.project_id, f.rel_path AS title, f.blurb AS content,
                       f.root_path, f.mtime, 'catalog' AS kind
                FROM fs_catalog f
                WHERE f.is_dir = FALSE AND (f.rel_path LIKE ? OR COALESCE(f.blurb, '') LIKE ?)
                ORDER BY f.mtime DESC NULLS LAST LIMIT ?
                """,
                (pattern, pattern, limit),
            )
            for row in cur.fetchall():
                item = dict(row)
                item["path"] = f"{item['root_path'].rstrip('/')}/{item['title']}"
                item["source"] = "keyword"
                results.append(item)

        if "chunk" in want and not hub_mode:
            cur.execute(
                """
                SELECT id, project_id, path, chunk_index, substr(content, 1, 300) AS content,
                       'chunk' AS kind
                FROM file_chunks
                WHERE content LIKE ?
                ORDER BY id DESC LIMIT ?
                """,
                (pattern, limit),
            )
            for row in cur.fetchall():
                item = dict(row)
                item["title"] = f"{item['path']} #{item['chunk_index']}"
                item["source"] = "keyword"
                results.append(item)

    return results


def vector_search(
    query: str,
    *,
    limit: int = 50,
    kinds: frozenset[str] | None = None,
    include_archived: bool = False,
) -> list[dict[str, Any]]:
    if not embeddings_available():
        return []
    query_vec = embed_one(query)
    if not query_vec:
        return []
    knn_kinds = tuple(k for k in VECTOR_KINDS if k in kinds) if kinds else VECTOR_KINDS
    if not knn_kinds:
        return []
    return knn(query_vec, kinds=knn_kinds, limit=limit, include_archived=include_archived)


def hybrid_search(
    query: str,
    *,
    limit: int = 50,
    include_archived: bool = False,
    hub_mode: bool = False,
    kinds: frozenset[str] | None = None,
    project_id: int | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
) -> dict[str, Any]:
    q = query.strip()
    if not q:
        return {"query": query, "results": [], "count": 0, "mode": "empty"}

    # Scoped searches filter after the legs run, so ask each leg for extra rows.
    scoped = has_scope(project_id, date_from, date_to)
    fetch = limit * 5 if scoped else limit

    keyword_hits = keyword_search(
        q, limit=fetch, include_archived=include_archived, hub_mode=hub_mode, kinds=kinds
    )
    vector_hits = vector_search(
        q, limit=fetch, kinds=kinds, include_archived=include_archived
    )

    fuzzy_hits: list[dict[str, Any]] = []
    if not hub_mode and len(keyword_hits) < 3:
        # Typo fallback: only when the exact legs found little.
        fuzzy_hits = fuzzy_search(q, limit=fetch, include_archived=include_archived, kinds=kinds)
        seen = {result_key(h) for h in keyword_hits}
        keyword_hits = keyword_hits + [h for h in fuzzy_hits if result_key(h) not in seen]

    if vector_hits:
        merged = reciprocal_rank_fusion(keyword_hits, vector_hits)
        mode = "hybrid"
    else:
        merged = keyword_hits
        for i, item in enumerate(merged):
            item = dict(item)
            item["rank"] = 1.0 / (RRF_K + i + 1)
            merged[i] = item
        mode = "keyword"

    if scoped:
        merged = filter_hits_by_scope(
            merged, project_id=project_id, date_from=date_from, date_to=date_to
        )
    merged = merged[:limit]
    if not hub_mode:
        merged = enrich_hits(merged, q)

    return {
        "query": query,
        "results": merged,
        "count": len(merged),
        "mode": mode,
        "fuzzy": bool(fuzzy_hits),
        "filters": {"project_id": project_id, "date_from": date_from, "date_to": date_to},
        "embeddings": embeddings_available(),
    }
