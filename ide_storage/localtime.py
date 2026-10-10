"""Display-side time formatting.

Rows are stored as naive UTC ISO strings (``datetime.utcnow().isoformat()``).
Anything a human reads — vault notes, wiki pages, howl summaries, search titles —
goes through here so it shows local wall-clock time as ``HH:MM MM/DD/YYYY``.

The zone comes from ``WOLF_TZ`` (or ``TZ``); default ``America/Chicago``.
"""
from __future__ import annotations

import os
from datetime import datetime, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

DEFAULT_TZ = "America/Chicago"
DISPLAY = "%H:%M %m/%d/%Y"
STAMP = "%Y-%m-%d-%H%M"  # filenames/URLs: sortable, local


def local_tz():
    name = os.environ.get("WOLF_TZ") or os.environ.get("TZ") or DEFAULT_TZ
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return timezone.utc


def parse_utc(iso: str | None) -> datetime | None:
    if not iso:
        return None
    s = str(iso).strip().replace(" ", "T")
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def to_local(iso: str | None) -> datetime | None:
    dt = parse_utc(iso)
    return dt.astimezone(local_tz()) if dt else None


def fmt(iso: str | None, default: str = "") -> str:
    """``HH:MM MM/DD/YYYY`` in local time, or ``default`` if unparseable."""
    dt = to_local(iso)
    return dt.strftime(DISPLAY) if dt else default


def fmt_date(iso: str | None, default: str = "") -> str:
    dt = to_local(iso)
    return dt.strftime("%m/%d/%Y") if dt else default


def stamp(iso: str | None) -> str:
    """Local, filesystem-safe, sortable: ``YYYY-MM-DD-HHMM``."""
    dt = to_local(iso)
    return dt.strftime(STAMP) if dt else "unknown"


def now_display() -> str:
    return datetime.now(local_tz()).strftime(DISPLAY)
