"""Session activity log — short human summaries written on each /save."""
from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from typing import Any, Optional

# Canonical metadata key. pickup_override is a legacy alias.
LEFT_OFF_KEY = "where_we_left_off"
LEFT_OFF_UPDATED_KEY = "where_we_left_off_at"
LEGACY_OVERRIDE_KEY = "pickup_override"

_GENERIC_CONTENT_RE = re.compile(
    r"(?i)^(saved\s+\d+\s+messages|agent conversation|chat\s*#?\d+)\b"
)
_TIMESTAMP_RE = re.compile(r"<timestamp>.*?</timestamp>\s*", re.I | re.DOTALL)
_FILLER_RE = re.compile(
    r"(?i)^(sure|okay|ok|yes|yeah|alright|got it|sounds good|here(?:'s| is)|i(?:'| a)m going to)\b"
)
_SIGNAL_RE = re.compile(
    r"(?i)\b(shipped|fixed|implemented|deployed|added|removed|updated|built|"
    r"finished|completed|migrated|refactored|verified|resolved|installed|"
    r"where we left off|left off|next step|still need|unfinished)\b"
)


def parse_metadata(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return dict(raw)
    if isinstance(raw, str) and raw.strip():
        try:
            parsed = json.loads(raw)
            return parsed if isinstance(parsed, dict) else {}
        except json.JSONDecodeError:
            return {}
    return {}


def clean_title(title: str) -> str:
    t = (title or "").strip()
    if t.lower().startswith("chat #"):
        t = t[6:].strip() or t
    t = _TIMESTAMP_RE.sub("", t).strip()
    return t or (title or "").strip() or "Session"


def get_saved_left_off(project: dict[str, Any]) -> Optional[str]:
    meta = parse_metadata(project.get("metadata"))
    for key in (LEFT_OFF_KEY, LEGACY_OVERRIDE_KEY):
        val = meta.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()
    return None


def get_left_off_updated_at(project: dict[str, Any]) -> Optional[str]:
    meta = parse_metadata(project.get("metadata"))
    at = meta.get(LEFT_OFF_UPDATED_KEY)
    return at.strip() if isinstance(at, str) and at.strip() else None


def ensure_brief_url(text: str, brief_url: str) -> str:
    t = (text or "").strip()
    if not t or not brief_url:
        return t
    if "agent-brief" in t or brief_url in t or re.search(r"(?i)\bbrief:\s*http", t):
        return t
    return f"{t.rstrip()}\nBrief: {brief_url}"


def resolve_pickup(
    project: dict[str, Any],
    *,
    default_pickup: str,
    brief_url: str = "",
) -> tuple[str, bool]:
    saved = get_saved_left_off(project)
    if saved:
        return ensure_brief_url(saved, brief_url), True
    return default_pickup, False


def metadata_with_left_off(
    project: dict[str, Any],
    content: Optional[str],
    *,
    updated_at: Optional[str] = None,
) -> dict[str, Any]:
    meta = parse_metadata(project.get("metadata"))
    now = updated_at or datetime.now(timezone.utc).replace(tzinfo=None).isoformat()
    text = (content or "").strip()
    if text:
        meta[LEFT_OFF_KEY] = text
        meta[LEFT_OFF_UPDATED_KEY] = now
        meta[LEGACY_OVERRIDE_KEY] = text
    else:
        meta.pop(LEFT_OFF_KEY, None)
        meta.pop(LEFT_OFF_UPDATED_KEY, None)
        meta.pop(LEGACY_OVERRIDE_KEY, None)
    return meta


def _clip(text: str, max_len: int) -> str:
    t = re.sub(r"\s+", " ", (text or "").strip())
    if len(t) <= max_len:
        return t
    cut = t[: max_len - 1].rsplit(" ", 1)[0].rstrip(" ,.;:")
    return (cut or t[: max_len - 1]).rstrip() + "…"


def _usable_content(content: Optional[str]) -> bool:
    c = (content or "").strip()
    if len(c) < 24:
        return False
    if _GENERIC_CONTENT_RE.match(c):
        return False
    return True


def build_session_log_summary(
    *,
    title: str = "",
    messages: Optional[list[dict[str, Any]]] = None,
    extracted_memories: Optional[list[dict[str, Any]]] = None,
    max_len: int = 480,
) -> str:
    """
    Short user-facing paragraph for one saved session (log-book entry).
    Prefer extracted memories from this save; else signal lines from assistants;
    else cleaned title + last user ask.
    """
    parts: list[str] = []
    seen: set[str] = set()

    def add(text: str) -> None:
        t = re.sub(r"\s+", " ", (text or "").strip())
        if len(t) < 12:
            return
        key = t[:100].lower()
        if key in seen:
            return
        seen.add(key)
        parts.append(t)

    for m in extracted_memories or []:
        typ = (m.get("type") or "").lower()
        if typ not in ("active_work", "decision", "problem", "goal"):
            continue
        add(m.get("content") or "")
        if len(parts) >= 3:
            break

    if len(parts) < 2:
        for msg in reversed(messages or []):
            if (msg.get("role") or "") != "assistant":
                continue
            body = (msg.get("content") or "").strip()
            if len(body) < 40:
                continue
            for para in re.split(r"\n{2,}", body):
                line = para.strip().split("\n")[0].strip()
                line = re.sub(r"^#+\s*", "", line)
                line = re.sub(r"^\*\*?|\*\*?$", "", line).strip()
                if len(line) < 30 or _FILLER_RE.match(line):
                    continue
                if _SIGNAL_RE.search(line) or len(parts) < 1:
                    add(line)
                if len(parts) >= 2:
                    break
            if len(parts) >= 2:
                break

    if not parts:
        last_user = ""
        for msg in reversed(messages or []):
            if (msg.get("role") or "") == "user":
                last_user = (msg.get("content") or "").strip()
                break
        title_bit = clean_title(title)
        if last_user and len(last_user) > 20:
            ask = _clip(last_user, 180)
            add(f"Worked on: {ask}")
        elif title_bit and not _GENERIC_CONTENT_RE.match(title_bit):
            add(title_bit)
        else:
            add("Session checkpointed — see agent brief for technical detail.")

    # Turn bullets into one short paragraph.
    if len(parts) == 1:
        summary = parts[0]
    else:
        summary = parts[0].rstrip(".") + ". " + " ".join(
            p if p[:1].isupper() else p[:1].upper() + p[1:] for p in parts[1:]
        )
    return _clip(summary, max_len)


def log_entry_from_chat(chat: dict[str, Any]) -> dict[str, Any]:
    """Normalize a chat row into a logbook entry."""
    from .session_time import effective_occurred_at

    summary = (chat.get("content") or "").strip()
    title = clean_title(chat.get("title") or f"Session #{chat.get('id', '?')}")
    if not _usable_content(summary):
        summary = title
    when = effective_occurred_at(chat)
    return {
        "chat_id": chat.get("id"),
        "title": title,
        "summary": summary,
        "occurred_at": when,
        "updated_at": when,  # UI historically used updated_at for display date
        "saved_at": chat.get("updated_at"),
        "web": None,
    }


def left_off_payload(
    project: dict[str, Any],
    *,
    brief_url: str = "",
    log_entries: Optional[list[dict[str, Any]]] = None,
    default_pickup: str = "",
) -> dict[str, Any]:
    """Payload for UI logbook + agent pickup."""
    entries = [
        log_entry_from_chat(e) if "summary" not in e or "chat_id" not in e else e
        for e in (log_entries or [])
    ]
    # Newest on timeline first (already sorted by query, but keep safe).
    entries.sort(key=lambda e: e.get("occurred_at") or e.get("updated_at") or "", reverse=True)
    latest = entries[0] if entries else None
    latest_summary = (latest or {}).get("summary") or get_saved_left_off(project) or ""
    pickup, from_saved = resolve_pickup(
        project,
        default_pickup=latest_summary or default_pickup,
        brief_url=brief_url,
    )
    if latest_summary and not get_saved_left_off(project):
        pickup = ensure_brief_url(latest_summary, brief_url)
        from_saved = True
    return {
        "heading": "Logbook",
        "latest": latest,
        "entries": entries,
        "saved": get_saved_left_off(project) or (latest_summary or None),
        "saved_at": get_left_off_updated_at(project) or ((latest or {}).get("occurred_at")),
        "pickup": pickup,
        "from_saved": from_saved,
    }


def apply_log_summary_to_chat(
    chat_id: int,
    summary: str,
    *,
    project: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    """
    Write the session log paragraph onto the chat and refresh project left-off metadata.
    Called from the post-save pipeline.
    """
    from .db import db_conn

    text = (summary or "").strip()
    now = datetime.utcnow().isoformat()
    with db_conn() as conn:
        cur = conn.cursor()
        if text:
            # Don't clobber a hand-written summary that is already good unless
            # it's the generic placeholder from Mac saves.
            cur.execute("SELECT content FROM chats WHERE id = ?", (chat_id,))
            row = cur.fetchone()
            existing = (row["content"] if row else "") or ""
            if not _usable_content(existing) or len(text) >= len(existing.strip()):
                cur.execute(
                    "UPDATE chats SET content = ?, updated_at = ? WHERE id = ?",
                    (text, now, chat_id),
                )
        meta_written = False
        if project is not None and text:
            meta = metadata_with_left_off(project, text, updated_at=now)
            cur.execute(
                "UPDATE projects SET metadata = ?, updated_at = ? WHERE id = ?",
                (json.dumps(meta), now, project["id"]),
            )
            meta_written = True
        conn.commit()
    return {"chat_id": chat_id, "summary": text, "metadata_updated": meta_written}
