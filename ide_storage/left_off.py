"""Where we left off — saved pickup spot + auto last-activity snapshot."""
from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from typing import Any, Optional

# Canonical metadata key. pickup_override is accepted as a legacy alias
# (already present on some projects, e.g. imessage-archive).
LEFT_OFF_KEY = "where_we_left_off"
LEFT_OFF_UPDATED_KEY = "where_we_left_off_at"
LEGACY_OVERRIDE_KEY = "pickup_override"


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


def get_saved_left_off(project: dict[str, Any]) -> Optional[str]:
    """Return the user-saved left-off spot, if any."""
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


def _clean_title(title: str) -> str:
    t = (title or "").strip()
    if t.lower().startswith("chat #"):
        t = t[6:].strip() or t
    # Drop Cursor-injected timestamp wrappers when they ate the real title.
    t = re.sub(r"<timestamp>.*?</timestamp>\s*", "", t, flags=re.I | re.DOTALL).strip()
    return t or title


def build_auto_snapshot(
    *,
    archived_recent_sessions: Optional[list[dict[str, Any]]] = None,
    active_sessions: Optional[list[dict[str, Any]]] = None,
    memories: Optional[list[dict[str, Any]]] = None,
    max_items: int = 5,
) -> dict[str, Any]:
    """Derive last-activity + open items from sessions and active_work memories."""
    last_activity: Optional[dict[str, Any]] = None
    for pool, kind in (
        (archived_recent_sessions or [], "archived"),
        (active_sessions or [], "active"),
    ):
        if pool:
            s = pool[0]
            last_activity = {
                "kind": kind,
                "chat_id": s.get("id"),
                "title": _clean_title(s.get("title") or f"session #{s.get('id', '?')}"),
                "updated_at": s.get("updated_at"),
            }
            break

    open_items: list[str] = []
    seen: set[str] = set()
    for m in memories or []:
        if (m.get("type") or "") != "active_work":
            continue
        content = (m.get("content") or "").strip()
        if len(content) < 8:
            continue
        key = content[:120].lower()
        if key in seen:
            continue
        seen.add(key)
        open_items.append(content[:350])
        if len(open_items) >= max_items:
            break

    lines: list[str] = []
    if last_activity:
        when = last_activity.get("updated_at") or ""
        date_bit = f" ({when[:10]})" if when and len(str(when)) >= 10 else ""
        label = "Last checkpoint" if last_activity["kind"] == "archived" else "Active session"
        lines.append(f"{label}{date_bit}: {last_activity['title']}")
    if open_items:
        lines.append("Open items:")
        for i, item in enumerate(open_items, 1):
            lines.append(f"  {i}. {item}")
    summary = "\n".join(lines).strip()
    return {
        "last_activity": last_activity,
        "open_items": open_items,
        "summary": summary,
    }


def suggest_left_off_text(
    *,
    project: dict[str, Any],
    brief_url: str = "",
    archived_recent_sessions: Optional[list[dict[str, Any]]] = None,
    active_sessions: Optional[list[dict[str, Any]]] = None,
    memories: Optional[list[dict[str, Any]]] = None,
) -> str:
    """Propose text for the saved spot from current auto snapshot."""
    snap = build_auto_snapshot(
        archived_recent_sessions=archived_recent_sessions,
        active_sessions=active_sessions,
        memories=memories,
    )
    name = project.get("name") or project.get("slug") or "project"
    parts = [f"Where we left off on {name}:"]
    if snap["summary"]:
        parts.append(snap["summary"])
    else:
        parts.append("No recent sessions or active_work memories yet.")
    if brief_url:
        parts.append(f"Brief: {brief_url}")
    return "\n".join(parts).strip()


def ensure_brief_url(text: str, brief_url: str) -> str:
    """Append brief URL if the saved spot doesn't already mention a brief link."""
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
    """
    Return (pickup_text, from_saved).
    Saved where_we_left_off / pickup_override wins over the auto tier prompt.
    """
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
    """
    Merge saved left-off into project metadata.
    Empty/None content clears both canonical and legacy keys.
    """
    meta = parse_metadata(project.get("metadata"))
    now = updated_at or datetime.now(timezone.utc).replace(tzinfo=None).isoformat()
    text = (content or "").strip()
    if text:
        meta[LEFT_OFF_KEY] = text
        meta[LEFT_OFF_UPDATED_KEY] = now
        # Keep legacy key in sync so older briefs/tools still see it.
        meta[LEGACY_OVERRIDE_KEY] = text
    else:
        meta.pop(LEFT_OFF_KEY, None)
        meta.pop(LEFT_OFF_UPDATED_KEY, None)
        meta.pop(LEGACY_OVERRIDE_KEY, None)
    return meta


def left_off_payload(
    project: dict[str, Any],
    *,
    brief_url: str = "",
    archived_recent_sessions: Optional[list[dict[str, Any]]] = None,
    active_sessions: Optional[list[dict[str, Any]]] = None,
    memories: Optional[list[dict[str, Any]]] = None,
    default_pickup: str = "",
) -> dict[str, Any]:
    """Full payload for UI + agent brief."""
    saved = get_saved_left_off(project)
    auto = build_auto_snapshot(
        archived_recent_sessions=archived_recent_sessions,
        active_sessions=active_sessions,
        memories=memories,
    )
    pickup, from_saved = resolve_pickup(
        project, default_pickup=default_pickup or auto.get("summary") or "", brief_url=brief_url
    )
    return {
        "heading": "Where we left off",
        "saved": saved,
        "saved_at": get_left_off_updated_at(project),
        "auto": auto,
        "pickup": pickup,
        "from_saved": from_saved,
        "suggest": suggest_left_off_text(
            project=project,
            brief_url=brief_url,
            archived_recent_sessions=archived_recent_sessions,
            active_sessions=active_sessions,
            memories=memories,
        ),
    }
