"""Conversation-level search helpers.

What this adds on top of the keyword and vector legs in ``search_ops``:

* **Fuzzy fallback** - typo-tolerant word matching (``lid clsoe`` finds ``lid close``)
  used only when the exact legs find little.
* **Scope filters** - project, and from/to dates, applied to any hit.
* **Context** - each message hit shows the messages around it and the date it
  was said, and lists the decisions/memories that were saved from that chat.
* **Window embeddings** - each chat is cut into windows of a few messages and
  embedded, so a question about *what was discussed* can match the moment.
* **Timelines** - one project's chats, decisions and howls in date order.
"""
from __future__ import annotations

import difflib
import re
from datetime import datetime, timezone
from typing import Any, Iterable

from ide_storage import localtime as LT
from ide_storage.db import db_conn
from ide_storage.embed_index import _existing_hashes, _upsert_embedding, text_hash
from ide_storage.embeddings import embed_one, embeddings_available

WINDOW_KIND = "convo"
WINDOW_SIZE = 8
WINDOW_MAX_CHARS = 2000
FUZZY_MIN_RATIO = 0.78
FUZZY_SCAN_LIMIT = 20000
SNIPPET_WIDTH = 200
_TOKEN_RE = re.compile(r"[a-z0-9']+")


# --- scope -----------------------------------------------------------------

def _in_scope(
    at: str | None,
    project_id: int | None,
    row_project: int | None,
    date_from: str | None,
    date_to: str | None,
) -> bool:
    if project_id is not None and row_project != project_id:
        return False
    if date_from and (not at or at < date_from):
        return False
    if date_to and (not at or at > date_to + "~"):
        # ISO timestamps sort as text and "~" sorts after "T", so the whole end day is kept.
        return False
    return True


def has_scope(project_id: int | None, date_from: str | None, date_to: str | None) -> bool:
    return project_id is not None or bool(date_from) or bool(date_to)


def _scope_lookup(kind: str, ids: Iterable[int]) -> dict[int, tuple[int | None, str | None]]:
    """Map id -> (project_id, timestamp) for one result kind."""
    ids = sorted({int(i) for i in ids})
    if not ids:
        return {}
    marks = ",".join("?" * len(ids))
    sql = {
        "memory": f"SELECT id, project_id, created_at AS at FROM memories WHERE id IN ({marks})",
        "chat": f"SELECT id, project_id, occurred_at AS at FROM chats WHERE id IN ({marks})",
        "howl": f"SELECT id, project_id, created_at AS at FROM howls WHERE id IN ({marks})",
        "message": (
            "SELECT m.id, c.project_id, m.created_at AS at FROM messages m "
            f"JOIN chats c ON c.id = m.chat_id WHERE m.id IN ({marks})"
        ),
        "convo": (
            "SELECT m.id, c.project_id, m.created_at AS at FROM messages m "
            f"JOIN chats c ON c.id = m.chat_id WHERE m.id IN ({marks})"
        ),
        "project": f"SELECT id, id AS project_id, NULL AS at FROM projects WHERE id IN ({marks})",
    }.get(kind)
    if sql is None:
        return {}
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(sql, tuple(ids))
        return {int(r["id"]): (r["project_id"], r["at"]) for r in cur.fetchall()}


def filter_hits_by_scope(
    hits: list[dict[str, Any]],
    *,
    project_id: int | None,
    date_from: str | None,
    date_to: str | None,
) -> list[dict[str, Any]]:
    """Keep only hits inside the project and date window. Kinds with no date or
    project link (chunks, catalog) are dropped whenever a scope is set."""
    if not has_scope(project_id, date_from, date_to):
        return hits
    by_kind: dict[str, list[int]] = {}
    for h in hits:
        by_kind.setdefault(h["kind"], []).append(int(h["id"]))
    lookups = {k: _scope_lookup(k, ids) for k, ids in by_kind.items()}
    kept = []
    for h in hits:
        found = lookups.get(h["kind"], {}).get(int(h["id"]))
        if found is None:
            continue
        row_project, at = found
        if _in_scope(at, project_id, row_project, date_from, date_to):
            kept.append(h)
    return kept


# --- fuzzy fallback --------------------------------------------------------

def _word_matches(word: str, text: str, tokens: set[str]) -> bool:
    if word in text:
        return True
    for tok in tokens:
        if abs(len(tok) - len(word)) > 2:
            continue
        if len(word) >= 4 and tok.startswith(word):
            return True
        if difflib.SequenceMatcher(None, word, tok).ratio() >= FUZZY_MIN_RATIO:
            return True
    return False


def fuzzy_search(
    query: str,
    *,
    limit: int = 50,
    include_archived: bool = False,
    kinds: frozenset[str] | None = None,
) -> list[dict[str, Any]]:
    """Typo-tolerant search over messages and memories. Every word (3+ letters)
    must match, either exactly, as a prefix, or within a small edit distance."""
    words = [w.lower() for w in query.split() if len(w) >= 3]
    if not words:
        return []
    want = kinds or frozenset({"message", "memory"})
    chat_filter = "" if include_archived else " AND COALESCE(c.status, 'active') = 'active'"
    out: list[dict[str, Any]] = []

    def accept(text: str) -> bool:
        lowered = text.lower()
        tokens = set(_TOKEN_RE.findall(lowered))
        return all(_word_matches(w, lowered, tokens) for w in words)

    with db_conn() as conn:
        cur = conn.cursor()
        if "message" in want:
            cur.execute(
                f"""
                SELECT m.id, m.chat_id, m.role, m.content, m.created_at,
                       c.title AS chat_title, c.project_id
                FROM messages m JOIN chats c ON c.id = m.chat_id
                WHERE 1=1{chat_filter}
                ORDER BY m.created_at DESC LIMIT ?
                """,
                (FUZZY_SCAN_LIMIT,),
            )
            for row in cur.fetchall():
                if len(out) >= limit:
                    break
                if accept(row["content"] or ""):
                    item = dict(row)
                    item["kind"] = "message"
                    item["title"] = item.get("chat_title") or "Conversation"
                    item["content"] = _snippet(row["content"] or "", words)
                    item["source"] = "fuzzy"
                    out.append(item)
        if "memory" in want and len(out) < limit:
            cur.execute(
                """
                SELECT m.id, m.type, m.content, m.project_id, m.created_at
                FROM memories m
                WHERE COALESCE(m.status, 'active') = 'active'
                ORDER BY m.created_at DESC LIMIT ?
                """,
                (FUZZY_SCAN_LIMIT,),
            )
            for row in cur.fetchall():
                if len(out) >= limit:
                    break
                if accept(row["content"] or ""):
                    item = dict(row)
                    item["kind"] = "memory"
                    item["memory_type"] = item.pop("type")
                    item["title"] = f"[{item['memory_type']}] {(row['content'] or '')[:120]}"
                    item["content"] = _snippet(row["content"] or "", words)
                    item["source"] = "fuzzy"
                    out.append(item)
    return out


# --- enrichment ------------------------------------------------------------

def _snippet(text: str, words: list[str], width: int = SNIPPET_WIDTH) -> str:
    """A window of ``text`` centred on the first query word, so the match is visible."""
    lowered = text.lower()
    idx = -1
    for w in words:
        idx = lowered.find(w.lower())
        if idx >= 0:
            break
    if idx < 0 or len(text) <= width:
        return text[:width]
    start = max(0, idx - width // 3)
    piece = text[start:start + width]
    return ("..." if start else "") + piece + ("..." if start + width < len(text) else "")


def enrich_hits(hits: list[dict[str, Any]], query: str) -> list[dict[str, Any]]:
    """Add a readable date, nearby messages, and linked decisions to each hit."""
    words = [w for w in query.split() if w]
    message_ids = [int(h["id"]) for h in hits if h["kind"] in ("message", "convo")]
    chat_ids = {int(h["chat_id"]) for h in hits if h.get("chat_id") is not None}
    chat_ids |= {int(h["id"]) for h in hits if h["kind"] == "chat"}

    decisions: dict[int, list[dict[str, Any]]] = {}
    with db_conn() as conn:
        cur = conn.cursor()
        if chat_ids:
            marks = ",".join("?" * len(chat_ids))
            cur.execute(
                f"""
                SELECT id, source_chat_id, type, content, created_at FROM memories
                WHERE source_chat_id IN ({marks}) AND COALESCE(status, 'active') = 'active'
                ORDER BY created_at
                """,
                tuple(chat_ids),
            )
            for row in cur.fetchall():
                decisions.setdefault(int(row["source_chat_id"]), []).append(
                    {"id": row["id"], "type": row["type"], "content": row["content"][:300],
                     "created_at": row["created_at"], "when": LT.fmt(row["created_at"])}
                )

        full_text: dict[int, str] = {}
        if message_ids:
            marks = ",".join("?" * len(message_ids))
            cur.execute(f"SELECT id, content FROM messages WHERE id IN ({marks})", tuple(message_ids))
            full_text = {int(r["id"]): r["content"] for r in cur.fetchall()}

        for h in hits:
            at = h.get("created_at") or h.get("occurred_at") or h.get("at") or h.get("updated_at")
            h["when"] = LT.fmt(at) if at else ""
            h["when_iso"] = at or ""
            if h["kind"] in ("message", "convo"):
                mid = int(h["id"])
                if mid in full_text:
                    h["content"] = _snippet(full_text[mid], words)
                cid = h.get("chat_id")
                if cid is not None:
                    cur.execute(
                        """
                        SELECT id, role, content, created_at FROM messages
                        WHERE chat_id = ? AND id BETWEEN ? AND ? AND id != ?
                        ORDER BY id
                        """,
                        (cid, mid - 2, mid + 2, mid),
                    )
                    h["context"] = [
                        {"role": r["role"], "content": r["content"][:160],
                         "when": LT.fmt(r["created_at"])}
                        for r in cur.fetchall()
                    ]
            if h["kind"] in ("message", "convo"):
                cid = h.get("chat_id")
            elif h["kind"] == "chat":
                cid = h["id"]
            else:
                cid = None
            if cid is not None:
                h["decisions"] = decisions.get(int(cid), [])
    return hits


# --- timelines -------------------------------------------------------------

def project_timeline(project_id: int, *, limit: int = 200) -> list[dict[str, Any]]:
    """Chats, saved memories and howls for one project, newest first."""
    items: list[dict[str, Any]] = []
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, title, occurred_at AS at FROM chats
            WHERE project_id = ? AND COALESCE(status, 'active') = 'active'
            ORDER BY occurred_at DESC LIMIT ?
            """,
            (project_id, limit),
        )
        for r in cur.fetchall():
            items.append({"kind": "chat", "id": r["id"], "title": r["title"] or "Chat", "at": r["at"]})
        cur.execute(
            """
            SELECT id, type, content, created_at AS at FROM memories
            WHERE project_id = ? AND COALESCE(status, 'active') = 'active'
            ORDER BY created_at DESC LIMIT ?
            """,
            (project_id, limit),
        )
        for r in cur.fetchall():
            items.append({"kind": "memory", "id": r["id"], "memory_type": r["type"],
                          "title": r["content"][:160], "at": r["at"]})
        cur.execute(
            """
            SELECT id, summary, created_at AS at FROM howls
            WHERE project_id = ? ORDER BY created_at DESC LIMIT ?
            """,
            (project_id, limit),
        )
        for r in cur.fetchall():
            items.append({"kind": "howl", "id": r["id"], "title": (r["summary"] or "")[:160], "at": r["at"]})
    for it in items:
        it["when"] = LT.fmt(it["at"]) if it.get("at") else ""
    items.sort(key=lambda it: it.get("at") or "", reverse=True)
    return items[:limit]


# --- window embeddings -----------------------------------------------------

def window_text(rows: list[dict[str, Any]]) -> str:
    lines = [f"{r['role']}: {r['content']}" for r in rows]
    return "\n".join(lines)[:WINDOW_MAX_CHARS]


def sync_conversation_windows(chat_ids: Iterable[int] | None = None) -> dict[str, int | str]:
    """Embed every window of ``WINDOW_SIZE`` messages that is new or changed.

    The embedding ``ref_id`` is the id of the window's first message, so a hit
    can point back to the exact moment in the chat. ``chat_ids`` limits the
    sync to those chats (used after each save); omit it to sync everything.
    """
    if not embeddings_available():
        return {"status": "embeddings unavailable"}
    report: dict[str, int | str] = {"status": "ok", "windows": 0, "embedded": 0, "unchanged": 0}
    with db_conn() as conn:
        cur = conn.cursor()
        hashes = _existing_hashes(cur, WINDOW_KIND)
        wanted = sorted({int(c) for c in chat_ids}) if chat_ids is not None else None
        if wanted == []:
            return report
        where = f" WHERE chat_id IN ({','.join('?' * len(wanted))})" if wanted else ""
        cur.execute(
            "SELECT id, chat_id, role, content, created_at FROM messages"
            + where + " ORDER BY chat_id, id",
            tuple(wanted or ()),
        )
        rows = [dict(r) for r in cur.fetchall()]
        by_chat: dict[int, list[dict[str, Any]]] = {}
        for r in rows:
            by_chat.setdefault(int(r["chat_id"]), []).append(r)

        now = datetime.now(timezone.utc).isoformat()
        for msgs in by_chat.values():
            for start in range(0, len(msgs), WINDOW_SIZE):
                window = msgs[start:start + WINDOW_SIZE]
                report["windows"] += 1
                text = window_text(window)
                if not text.strip():
                    continue
                ref = int(window[0]["id"])
                th = text_hash(text)
                if hashes.get(ref) == th:
                    report["unchanged"] += 1
                    continue
                vec = embed_one(text)
                if not vec:
                    continue
                _upsert_embedding(
                    cur, kind=WINDOW_KIND, ref_id=ref, embed_text=text, vector=vec, now=now
                )
                report["embedded"] += 1
        conn.commit()
    return report
