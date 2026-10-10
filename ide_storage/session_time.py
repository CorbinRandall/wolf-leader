"""Session timeline helpers — occurred_at is when the chat happened, not when it was saved."""
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

# Cursor often wraps real chat time in title: <timestamp>Thursday, Jul 2, 2026, 2:35 PM (UTC-7)</timestamp>
_TIMESTAMP_WRAPPER_RE = re.compile(
    r"<timestamp>\s*(.*?)\s*</timestamp>",
    re.IGNORECASE | re.DOTALL,
)
_TZ_PAREN_RE = re.compile(r"\s*\(UTC([+-]\d{1,2})(?::(\d{2}))?\)\s*$", re.IGNORECASE)

_HUMAN_TS_FORMATS = (
    "%A, %b %d, %Y, %I:%M %p",
    "%A, %B %d, %Y, %I:%M %p",
    "%a, %b %d, %Y, %I:%M %p",
    "%Y-%m-%dT%H:%M:%S.%f",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%d",
)


def _apply_utc_offset(dt: datetime, hours: int, minutes: int = 0) -> datetime:
    """Interpret naive wall clock as offset-from-UTC, return naive UTC."""
    offset = timedelta(hours=hours, minutes=minutes if hours >= 0 else -minutes)
    aware = dt.replace(tzinfo=timezone(offset))
    return aware.astimezone(timezone.utc).replace(tzinfo=None)


def parse_datetime(raw: Optional[str]) -> Optional[datetime]:
    if not raw or not str(raw).strip():
        return None
    text = str(raw).strip()

    # ISO with Z / offset
    try:
        iso = text.replace("Z", "+00:00")
        dt = datetime.fromisoformat(iso)
        if dt.tzinfo is not None:
            return dt.astimezone(timezone.utc).replace(tzinfo=None)
        return dt
    except ValueError:
        pass

    tz_hours = tz_mins = None
    m = _TZ_PAREN_RE.search(text)
    if m:
        tz_hours = int(m.group(1))
        tz_mins = int(m.group(2) or 0)
        text = _TZ_PAREN_RE.sub("", text).strip()

    for fmt in _HUMAN_TS_FORMATS:
        try:
            dt = datetime.strptime(text, fmt)
            if tz_hours is not None:
                return _apply_utc_offset(dt, tz_hours, tz_mins or 0)
            return dt
        except ValueError:
            continue
    return None


def parse_title_timestamp(title: Optional[str]) -> Optional[datetime]:
    if not title:
        return None
    m = _TIMESTAMP_WRAPPER_RE.search(title)
    if m:
        return parse_datetime(m.group(1))
    # Bare human date in title without wrapper
    if re.search(r"\b20\d{2}\b", title) and re.search(r"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\b", title):
        return parse_datetime(title.strip())
    return None


def isoformat_utc(dt: Optional[datetime]) -> Optional[str]:
    if dt is None:
        return None
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
    return dt.isoformat()


def earliest_message_time(messages: Optional[list[dict[str, Any]]]) -> Optional[datetime]:
    best: Optional[datetime] = None
    for msg in messages or []:
        if not isinstance(msg, dict):
            continue
        for key in ("created_at", "timestamp", "time"):
            dt = parse_datetime(msg.get(key))
            if dt and (best is None or dt < best):
                best = dt
    return best


def infer_occurred_at(
    *,
    explicit: Optional[str] = None,
    title: Optional[str] = None,
    messages: Optional[list[dict[str, Any]]] = None,
    created_at: Optional[str] = None,
    transcript_mtime: Optional[float] = None,
) -> str:
    """
    Resolve when the session actually happened (for logbook ordering).

    Priority:
      1. explicit occurred_at from client/API
      2. <timestamp>…</timestamp> in title (often the real Cursor chat time)
      3. earliest message timestamp (when not identical to save-time created_at)
      4. transcript file mtime
      5. chat created_at / now
    """
    dt = parse_datetime(explicit)
    if dt:
        return isoformat_utc(dt)  # type: ignore[return-value]

    title_dt = parse_title_timestamp(title)
    if title_dt:
        return isoformat_utc(title_dt)  # type: ignore[return-value]

    created_dt = parse_datetime(created_at)
    msg_dt = earliest_message_time(messages)
    if msg_dt and (created_dt is None or msg_dt != created_dt):
        return isoformat_utc(msg_dt)  # type: ignore[return-value]

    if transcript_mtime:
        try:
            return datetime.utcfromtimestamp(float(transcript_mtime)).isoformat()
        except (TypeError, ValueError, OSError):
            pass

    if msg_dt:
        return isoformat_utc(msg_dt)  # type: ignore[return-value]
    if created_dt:
        return isoformat_utc(created_dt)  # type: ignore[return-value]
    return datetime.utcnow().isoformat()


def effective_occurred_at(chat: dict[str, Any]) -> str:
    """Value to sort/display for a chat row."""
    return (
        (chat.get("occurred_at") or "").strip()
        or (chat.get("created_at") or "").strip()
        or (chat.get("updated_at") or "").strip()
        or ""
    )
