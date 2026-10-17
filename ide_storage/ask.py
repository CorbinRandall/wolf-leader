"""Answer a plain question from the journal, without a language model.

"What did I learn for Wolf Leader three days ago?" has three parts the hub can read
directly: a project (Wolf Leader), a time (three days ago), and a kind of thing
(what was learned: decisions, problems, caveats). The answer is the saved memories and
sessions that match all three, grouped and quoted in full. Nothing is generated, so
nothing is made up, and it costs no more than a database query.

When a question names no project or time, the search results still come back.
"""
from __future__ import annotations

import json
import re
from datetime import datetime, timedelta
from typing import Any

from ide_storage import localtime as LT
from ide_storage.db import db_conn

_NUMBERS = {"a": 1, "an": 1, "one": 1, "two": 2, "couple": 2, "three": 3, "few": 3, "four": 4, "five": 5, "six": 6,
            "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fourteen": 14, "thirty": 30}
_MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
           "november", "december"]
_UNIT_DAYS = {"day": 1, "week": 7, "month": 30, "year": 365}

# What the question is about -> the kinds of memory that answer it.
_INTENTS: list[tuple[str, str, tuple[str, ...]]] = [
    (r"\b(learn\w*|lesson\w*|mistake\w*|takeaway\w*|figure\w* out|realiz\w*|discover\w*)\b", "what you learned",
     ("decision", "problem", "caveat", "constraint")),
    (r"\b(decid\w*|decision\w*|chose|choose|agreed?|settled?)\b", "what was decided", ("decision",)),
    (r"\b(problem\w*|issue\w*|bug\w*|broke\w*|fail\w*|wrong|stuck|block\w*|error\w*)\b", "what went wrong", ("problem", "caveat")),
    (r"\b(goal\w*|next|todo\w*|to-?do\w*|plan\w*|remaining|left to do)\b", "what is next", ("goal", "active_work")),
    (r"\b(rule\w*|constraint\w*|must|never|always|limit\w*)\b", "the rules", ("constraint", "caveat")),
]
_LABELS = {"decision": "Decisions", "problem": "Problems", "caveat": "Watch out for", "constraint": "Rules",
           "goal": "Goals", "active_work": "In progress", "note": "Notes"}


def _n(word: str) -> int | None:
    return int(word) if word.isdigit() else _NUMBERS.get(word)


def _day(d: datetime) -> datetime:
    return d.replace(hour=0, minute=0, second=0, microsecond=0)


def parse_when(text: str, now: datetime | None = None) -> dict[str, Any] | None:
    """A time window named in the question, in the hub's local time. None if it names none."""
    now = now or datetime.now(LT.local_tz()).replace(tzinfo=None)
    t = " " + re.sub(r"[^\w\s-]", " ", text.lower()) + " "
    today = _day(now)

    def window(start: datetime, end: datetime, label: str) -> dict[str, Any]:
        return {"start": start, "end": end, "label": label}

    if " today " in t or " this morning " in t or " tonight " in t:
        return window(today, today + timedelta(days=1), "today")
    if " yesterday " in t:
        return window(today - timedelta(days=1), today, "yesterday")
    m = re.search(r"\b(\w+)\s+(day|week|month|year)s?\s+ago\b", t)
    if m and _n(m.group(1)):
        n, unit = _n(m.group(1)), m.group(2)
        span = _UNIT_DAYS[unit]
        center = today - timedelta(days=n * span)
        if unit == "day":
            return window(center, center + timedelta(days=1), f"{n} day{'s' if n != 1 else ''} ago ({center:%b %-d})")
        # "three weeks ago" means around then, not one exact day.
        return window(center - timedelta(days=span // 2), center + timedelta(days=span // 2 + 1), f"about {n} {unit}{'s' if n != 1 else ''} ago")
    m = re.search(r"\b(?:last|past|previous)\s+(\w+)\s+(day|week|month)s\b", t)
    if m and _n(m.group(1)):
        n = _n(m.group(1)) * _UNIT_DAYS[m.group(2)]
        return window(today - timedelta(days=n), today + timedelta(days=1), f"the last {n} days")
    if re.search(r"\bthis week\b", t):
        start = today - timedelta(days=today.weekday())
        return window(start, today + timedelta(days=1), "this week")
    if re.search(r"\blast week\b", t):
        start = today - timedelta(days=today.weekday() + 7)
        return window(start, start + timedelta(days=7), "last week")
    if re.search(r"\b(recent\w*|lately)\b", t):
        return window(today - timedelta(days=7), today + timedelta(days=1), "the last 7 days")
    if re.search(r"\bthis month\b", t):
        return window(today.replace(day=1), today + timedelta(days=1), "this month")
    if re.search(r"\blast month\b", t):
        end = today.replace(day=1)
        start = (end - timedelta(days=1)).replace(day=1)
        return window(start, end, "last month")
    m = re.search(r"\b(" + "|".join(_MONTHS) + r"|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\w*\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b", t)
    if m:
        month = next(i for i, name in enumerate(_MONTHS, 1) if name.startswith(m.group(1)[:3]))
        try:
            day = datetime(now.year, month, int(m.group(2)))
        except ValueError:
            return None
        if day > today + timedelta(days=1):
            day = day.replace(year=now.year - 1)
        around = bool(re.search(r"\baround\b|\babout\b|\bnear\b", t))
        pad = 2 if around else 0
        return window(day - timedelta(days=pad), day + timedelta(days=pad + 1), f"{'around ' if around else ''}{day:%b %-d}")
    m = re.search(r"\bin\s+(" + "|".join(_MONTHS) + r")\b", t)
    if m:
        month = _MONTHS.index(m.group(1)) + 1
        year = now.year if month <= now.month else now.year - 1
        start = datetime(year, month, 1)
        end = datetime(year + (month == 12), month % 12 + 1, 1)
        return window(start, end, f"{start:%B %Y}")
    return None


def find_project(text: str, projects: list[dict[str, Any]]) -> dict[str, Any] | None:
    """The project a question names: the longest project name or slug that appears in it."""
    t = re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()
    best: tuple[int, dict[str, Any]] | None = None
    for project in projects:
        for raw in (project.get("name"), (project.get("slug") or "").replace("-", " ")):
            name = re.sub(r"[^a-z0-9]+", " ", (raw or "").lower()).strip()
            if len(name) >= 3 and re.search(rf"\b{re.escape(name)}\b", t):
                if best is None or len(name) > best[0]:
                    best = (len(name), project)
    return best[1] if best else None


def find_intent(text: str) -> tuple[str, tuple[str, ...]] | None:
    for pattern, label, kinds in _INTENTS:
        if re.search(pattern, text.lower()):
            return label, kinds
    return None


def _utc(local: datetime) -> str:
    """Local naive time -> the naive UTC text the journal stores."""
    from datetime import timezone

    return local.replace(tzinfo=LT.local_tz()).astimezone(timezone.utc).replace(tzinfo=None).isoformat()


def ask(question: str, *, limit: int = 40, now: datetime | None = None) -> dict[str, Any]:
    question = " ".join((question or "").split())
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, name, slug FROM projects WHERE COALESCE(status, 'active') != 'archived'")
        projects = [dict(r) for r in cur.fetchall()]
    project = find_project(question, projects)
    when = parse_when(question, now)
    intent = find_intent(question)
    names = {int(p["id"]): p["name"] for p in projects}

    sections: list[dict[str, Any]] = []
    sessions: list[dict[str, Any]] = []
    if project or when:
        where, args = ["1=1"], []
        if project:
            where.append("m.project_id = ?"); args.append(project["id"])
        if when:
            where.append("m.created_at >= ? AND m.created_at < ?"); args += [_utc(when["start"]), _utc(when["end"])]
        if intent:
            where.append(f"m.type IN ({','.join('?' * len(intent[1]))})"); args += list(intent[1])
        with db_conn() as conn:
            cur = conn.cursor()
            cur.execute(
                f"""
                SELECT m.id, m.type, m.content, m.project_id, m.source_chat_id, m.created_at
                FROM memories m WHERE {' AND '.join(where)} AND COALESCE(m.status, 'active') = 'active'
                ORDER BY m.created_at DESC, m.id DESC LIMIT ?
                """,
                (*args, limit * 3),
            )
            memories = [dict(r) for r in cur.fetchall()]
            chat_where, chat_args = ["1=1"], []
            if project:
                chat_where.append("c.project_id = ?"); chat_args.append(project["id"])
            if when:
                chat_where.append("COALESCE(c.occurred_at, c.created_at) >= ? AND COALESCE(c.occurred_at, c.created_at) < ?")
                chat_args += [_utc(when["start"]), _utc(when["end"])]
            cur.execute(
                f"""
                SELECT c.id, c.title, c.project_id, c.metadata, COALESCE(c.occurred_at, c.created_at) AS happened_at
                FROM chats c WHERE {' AND '.join(chat_where)}
                ORDER BY COALESCE(c.occurred_at, c.created_at) DESC LIMIT 12
                """,
                chat_args,
            )
            chats = [dict(r) for r in cur.fetchall()]
        order = list(intent[1]) if intent else ["decision", "problem", "caveat", "constraint", "goal", "active_work", "note"]
        for kind in order:
            items = [m for m in memories if m["type"] == kind][:limit]
            if items:
                sections.append({
                    "kind": kind, "title": _LABELS.get(kind, kind.title()),
                    "items": [{"memory_id": int(m["id"]), "text": m["content"], "when": m["created_at"],
                               "project_id": m["project_id"], "project": names.get(int(m["project_id"])) if m["project_id"] else None,
                               "chat_id": m["source_chat_id"]} for m in items],
                })
        for chat in chats:
            meta = chat.get("metadata")
            try:
                meta = json.loads(meta) if isinstance(meta, str) and meta else {}
            except ValueError:
                meta = {}
            sessions.append({"chat_id": int(chat["id"]), "title": " ".join((chat.get("title") or "Session").split())[:140],
                             "summary": (meta or {}).get("human_summary") or (meta or {}).get("agent_summary") or "",
                             "when": chat["happened_at"], "project_id": chat["project_id"],
                             "project": names.get(int(chat["project_id"])) if chat["project_id"] else None})

    found = sum(len(s["items"]) for s in sections)
    if project or when:
        about = intent[0] if intent else "what the journal holds"
        scope = " ".join(filter(None, [f"for {project['name']}" if project else "", f"from {when['label']}" if when else ""]))
        if found or sessions:
            parts = [f"{len(s['items'])} {s['title'].lower()}" for s in sections]
            if sessions:
                parts.append(f"{len(sessions)} session{'s' if len(sessions) != 1 else ''}")
            summary = f"Here is {about} {scope}: " + ", ".join(parts) + "."
        else:
            summary = f"Nothing saved {scope} about {about}. Try a wider time, or leave the time out."
    else:
        summary = ""

    try:
        from ide_storage.search_ops import hybrid_search

        results = hybrid_search(question, limit=60, include_archived=True, hub_mode=False).get("results", [])
    except Exception:  # noqa: BLE001
        results = []
    return {
        "question": question,
        "understood": {
            "project": {"id": project["id"], "name": project["name"]} if project else None,
            "when": when["label"] if when else None,
            "about": intent[0] if intent else None,
        },
        "summary": summary,
        "sections": sections,
        "sessions": sessions,
        "results": results,
    }
