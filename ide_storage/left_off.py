"""Session activity log — dual summaries on each /save.

- Human log (chats.content / UI Logbook): plain-language “what happened”
- Agent pickup (projects.metadata.where_we_left_off): technical handoff for agents
"""
from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from typing import Any, Optional

# Canonical metadata key. pickup_override is a legacy alias.
LEFT_OFF_KEY = "where_we_left_off"
LEFT_OFF_UPDATED_KEY = "where_we_left_off_at"
LEGACY_OVERRIDE_KEY = "pickup_override"
CHAT_AGENT_SUMMARY_KEY = "agent_summary"
CHAT_HUMAN_SUMMARY_KEY = "human_summary"

_GENERIC_CONTENT_RE = re.compile(
    r"(?i)^(saved\s+\d+\s+messages|synced\s+\d+\s+messages|agent conversation|"
    r"chat\s*#?\d+|checkpoint test)\b"
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
_AGENT_DENSE_RE = re.compile(
    r"(?i)\b(handoff_tier|pickup_override|agent-brief|SPEC\.yaml|do not redeploy|"
    r"LXC\s*\d+|bin/deploy|primary_hub|corbox-sshd)\b"
)
_PATH_HEAVY_RE = re.compile(r"(/[^\s]{8,})|(\d{1,3}(?:\.\d{1,3}){3})")


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


def _collect_parts(
    *,
    title: str,
    messages: Optional[list[dict[str, Any]]],
    extracted_memories: Optional[list[dict[str, Any]]],
    prefer_human: bool,
    max_parts: int = 3,
) -> list[str]:
    parts: list[str] = []
    seen: set[str] = set()

    def add(text: str) -> None:
        t = re.sub(r"\s+", " ", (text or "").strip())
        t = re.sub(r"\*\*?|`+", "", t)
        if len(t) < 12:
            return
        if prefer_human and _AGENT_DENSE_RE.search(t) and len(parts) > 0:
            return
        if prefer_human and len(_PATH_HEAVY_RE.findall(t)) >= 3 and len(t) > 160:
            # Keep a shorter clipped form instead of a path dump.
            t = _clip(t, 160)
        key = t[:100].lower()
        if key in seen:
            return
        seen.add(key)
        parts.append(t)

    memory_types = ("goal", "decision", "problem", "active_work") if prefer_human else (
        "active_work",
        "decision",
        "problem",
        "goal",
    )
    for m in extracted_memories or []:
        typ = (m.get("type") or "").lower()
        if typ not in memory_types:
            continue
        content = m.get("content") or ""
        if prefer_human and typ == "active_work" and _AGENT_DENSE_RE.search(content):
            continue
        add(content)
        if len(parts) >= max_parts:
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
                if prefer_human and _AGENT_DENSE_RE.search(line) and len(parts) >= 1:
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
            ask = _clip(last_user, 160 if prefer_human else 180)
            add(f"Worked on: {ask}" if prefer_human else f"Worked on: {ask}")
        elif title_bit and not _GENERIC_CONTENT_RE.match(title_bit):
            add(title_bit)
        else:
            add(
                "Session saved — open the archive for the full conversation."
                if prefer_human
                else "Session checkpointed — see agent brief for technical detail."
            )

    return parts


def _parts_to_paragraph(parts: list[str], max_len: int) -> str:
    if len(parts) == 1:
        summary = parts[0]
    else:
        summary = parts[0].rstrip(".") + ". " + " ".join(
            p if p[:1].isupper() else p[:1].upper() + p[1:] for p in parts[1:]
        )
    return _clip(summary, max_len)


def build_session_log_summary(
    *,
    title: str = "",
    messages: Optional[list[dict[str, Any]]] = None,
    extracted_memories: Optional[list[dict[str, Any]]] = None,
    max_len: int = 480,
) -> str:
    """
    Agent-oriented session summary (technical handoff / pickup).
    Kept as the historical name used by tests and the post-save pipeline.
    """
    parts = _collect_parts(
        title=title,
        messages=messages,
        extracted_memories=extracted_memories,
        prefer_human=False,
    )
    return _parts_to_paragraph(parts, max_len)


def build_human_log_summary(
    *,
    title: str = "",
    messages: Optional[list[dict[str, Any]]] = None,
    extracted_memories: Optional[list[dict[str, Any]]] = None,
    max_len: int = 360,
) -> str:
    """Plain-language logbook entry for the Wolf Leader web UI."""
    parts = _collect_parts(
        title=title,
        messages=messages,
        extracted_memories=extracted_memories,
        prefer_human=True,
        max_parts=2,
    )
    # Soften leading agent-ish openers for display.
    if parts:
        parts[0] = re.sub(
            r"(?i)^(fixed:|note:|decision:|constraint:)\s*",
            "",
            parts[0],
        ).strip() or parts[0]
    return _parts_to_paragraph(parts, max_len)


def humanize_log_summary(summary: str, *, title: str = "") -> str:
    """Best-effort display cleanup for older log entries."""
    s = (summary or "").strip()
    if not s or _GENERIC_CONTENT_RE.match(s):
        t = clean_title(title)
        return t if t and not _GENERIC_CONTENT_RE.match(t) else "Session saved."
    s = re.sub(r"\s+", " ", s)
    s = re.sub(r"\*\*?|`+", "", s)
    # Drop trailing Brief: URLs from UI copy.
    s = re.sub(r"(?i)\s*Brief:\s*https?://\S+\s*$", "", s).strip()
    if _AGENT_DENSE_RE.search(s) and len(s) > 220:
        s = _clip(s, 200)
    return s


def _chat_meta(chat: dict[str, Any]) -> dict[str, Any]:
    return parse_metadata(chat.get("metadata"))


def log_entry_from_chat(chat: dict[str, Any]) -> dict[str, Any]:
    """Normalize a chat row into a logbook entry (human summary for UI)."""
    from .session_time import effective_occurred_at

    meta = _chat_meta(chat)
    title = clean_title(chat.get("title") or f"Session #{chat.get('id', '?')}")
    raw = (chat.get("content") or "").strip()
    human = meta.get(CHAT_HUMAN_SUMMARY_KEY)
    if isinstance(human, str) and human.strip():
        summary = human.strip()
    else:
        summary = humanize_log_summary(raw, title=title) if raw else title
    if not _usable_content(summary):
        summary = title
    agent = meta.get(CHAT_AGENT_SUMMARY_KEY)
    if not (isinstance(agent, str) and agent.strip()) and _usable_content(raw):
        agent = raw
    when = effective_occurred_at(chat)
    return {
        "chat_id": chat.get("id"),
        "title": title,
        "summary": summary,
        "agent_summary": agent.strip() if isinstance(agent, str) else None,
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
    human_summary: Optional[str] = None,
    agent_summary: Optional[str] = None,
) -> dict[str, Any]:
    """
    Write the human logbook paragraph onto the chat; agent pickup onto the project.

    - chats.content → human-friendly log (UI)
    - chats.metadata.human_summary / agent_summary → both retained
    - projects.metadata.where_we_left_off → agent-oriented pickup
    """
    from .db import db_conn

    human = (human_summary if human_summary is not None else summary or "").strip()
    agent = (agent_summary if agent_summary is not None else summary or "").strip()
    now = datetime.utcnow().isoformat()
    with db_conn() as conn:
        cur = conn.cursor()
        if human or agent:
            cur.execute("SELECT content, metadata FROM chats WHERE id = ?", (chat_id,))
            row = cur.fetchone()
            if row is None:
                existing, raw_meta = "", None
            elif hasattr(row, "keys"):
                existing, raw_meta = (row["content"] or ""), row["metadata"]
            else:
                existing, raw_meta = (row[0] or ""), row[1]
            chat_meta = parse_metadata(raw_meta)
            if human:
                chat_meta[CHAT_HUMAN_SUMMARY_KEY] = human
            if agent:
                chat_meta[CHAT_AGENT_SUMMARY_KEY] = agent
            # Prefer writing the human paragraph into content for the Logbook UI.
            write_content = human or agent
            if write_content and (
                not _usable_content(existing) or len(write_content) >= len(existing.strip()) * 0.6
            ):
                cur.execute(
                    "UPDATE chats SET content = ?, metadata = ?, updated_at = ? WHERE id = ?",
                    (write_content, json.dumps(chat_meta), now, chat_id),
                )
            else:
                cur.execute(
                    "UPDATE chats SET metadata = ?, updated_at = ? WHERE id = ?",
                    (json.dumps(chat_meta), now, chat_id),
                )
        meta_written = False
        if project is not None and agent:
            meta = metadata_with_left_off(project, agent, updated_at=now)
            cur.execute(
                "UPDATE projects SET metadata = ?, updated_at = ? WHERE id = ?",
                (json.dumps(meta), now, project["id"]),
            )
            meta_written = True
        conn.commit()
    return {
        "chat_id": chat_id,
        "summary": human,
        "human_summary": human,
        "agent_summary": agent,
        "metadata_updated": meta_written,
    }
