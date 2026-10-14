"""A person's profile: who they are and how they like to work, kept for every AI tool to read.

AI tools each build one of these on their own (Claude's memory, Codex's AGENTS.md, Cursor's
rules, ChatGPT's saved memories). Here there is one per person, they can see and edit all of
it, and it travels with them from tool to tool. Items are short statements of one kind each.
"""
from __future__ import annotations

import re
from datetime import datetime
from typing import Any

from ide_storage.db import db_conn

KINDS = {
    "about": "About me",
    "preference": "How I like to work",
    "style": "How I like answers written",
    "tools": "My tools and setup",
    "avoid": "Please don't",
}
SOURCES = ("manual", "claude", "codex", "cursor", "chatgpt", "journal", "import")


def _now() -> str:
    return datetime.utcnow().isoformat()


def _person(name: str) -> str:
    from ide_storage.owners import canonical_owner, configured_owners

    resolved = canonical_owner(name)
    if resolved is None and configured_owners():
        raise LookupError(f"No person called {name}")
    return resolved or " ".join((name or "").split())


def _row(r: dict[str, Any]) -> dict[str, Any]:
    return {"id": int(r["id"]), "person": r["person"], "kind": r["kind"], "text": r["body"], "source": r["source"] or "manual",
            "created_at": r["created_at"], "updated_at": r["updated_at"]}


def profile(name: str) -> dict[str, Any]:
    person = _person(name)
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM profile_items WHERE lower(person) = lower(?) ORDER BY kind, id", (person,))
        items = [_row(dict(r)) for r in cur.fetchall()]
    sections = [{"kind": k, "title": t, "items": [i for i in items if i["kind"] == k]} for k, t in KINDS.items()]
    return {"person": person, "count": len(items), "sections": sections, "kinds": KINDS}


def _clean(text: str) -> str:
    return " ".join((text or "").split())[:1000]


def add_item(name: str, text: str, kind: str = "about", source: str = "manual") -> dict[str, Any]:
    person = _person(name)
    text = _clean(text)
    if not text:
        raise ValueError("Write something first")
    if kind not in KINDS:
        raise ValueError(f"kind is one of {list(KINDS)}")
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM profile_items WHERE lower(person) = lower(?) AND lower(body) = lower(?)", (person, text))
        existing = cur.fetchone()
        if existing:
            return _row(dict(existing))
        now = _now()
        cur.execute(
            "INSERT INTO profile_items (person, kind, body, source, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            (person, kind, text, source if source in SOURCES else "import", now, now),
        )
        item_id = int(cur.lastrowid)
        conn.commit()
        cur.execute("SELECT * FROM profile_items WHERE id = ?", (item_id,))
        return _row(dict(cur.fetchone()))


def update_item(item_id: int, text: str | None = None, kind: str | None = None) -> dict[str, Any]:
    changes: dict[str, Any] = {}
    if text is not None:
        changes["body"] = _clean(text)
        if not changes["body"]:
            raise ValueError("Write something first")
    if kind is not None:
        if kind not in KINDS:
            raise ValueError(f"kind is one of {list(KINDS)}")
        changes["kind"] = kind
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT 1 FROM profile_items WHERE id = ?", (item_id,))
        if not cur.fetchone():
            raise LookupError("item not found")
        if changes:
            sets = ", ".join(f"{k} = ?" for k in changes)
            cur.execute(f"UPDATE profile_items SET {sets}, updated_at = ? WHERE id = ?", (*changes.values(), _now(), item_id))
            conn.commit()
        cur.execute("SELECT * FROM profile_items WHERE id = ?", (item_id,))
        return _row(dict(cur.fetchone()))


def delete_item(item_id: int) -> dict[str, Any]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM profile_items WHERE id = ?", (item_id,))
        removed = cur.rowcount or 0
        conn.commit()
    if not removed:
        raise LookupError("item not found")
    return {"ok": True, "id": item_id}


def import_items(name: str, items: list[dict[str, Any]]) -> dict[str, Any]:
    """Add many items at once (from another tool). Exact duplicates are skipped."""
    before = profile(name)["count"]
    for item in items:
        try:
            add_item(name, item.get("text") or "", item.get("kind") or "about", item.get("source") or "import")
        except ValueError:
            continue
    after = profile(name)["count"]
    return {"added": after - before, "count": after}


def as_markdown(name: str) -> str:
    """The profile as an AI tool should read it."""
    data = profile(name)
    lines = [f"# About {data['person']}", "",
             "Kept in Wolf Leader and shared with every AI tool they use. Follow it; if something here seems out of date, ask.", ""]
    for section in data["sections"]:
        if section["items"]:
            lines += [f"## {section['title']}", ""] + [f"- {i['text']}" for i in section["items"]] + [""]
    if data["count"] == 0:
        lines.append("Nothing written yet.")
    return "\n".join(lines).rstrip() + "\n"


_FRONT = re.compile(r"^---\s*\n.*?\n---\s*\n", re.S)


def items_from_text(text: str, source: str, default_kind: str = "about") -> list[dict[str, Any]]:
    """Split a memory or rules file into profile items: one per bullet or short paragraph."""
    body = _FRONT.sub("", text or "")
    body = re.sub(r"\*\*(Why|How to apply):\*\*.*", "", body)  # keep the rule, not its bookkeeping
    out: list[dict[str, Any]] = []
    for chunk in re.split(r"\n\s*\n|\n(?=\s*[-*] )", body):
        line = re.sub(r"^\s*(#+|[-*]|\d+\.)\s*", "", chunk.strip())
        line = " ".join(line.split())
        if 12 <= len(line) <= 600 and not line.startswith(("```", "|", "<")):
            out.append({"text": line, "kind": guess_kind(line, default_kind), "source": source})
    return out


def guess_kind(text: str, default: str = "about") -> str:
    t = text.lower()
    if re.search(r"\b(don't|do not|never|avoid|stop)\b", t):
        return "avoid"
    if re.search(r"\b(reply|replies|answer|short|plain|tone|wording|write|explain|bullet|jargon)\b", t):
        return "style"
    if re.search(r"\b(mac|windows|linux|server|ssh|cursor|codex|claude|editor|terminal|unraid|docker)\b", t):
        return "tools"
    if re.search(r"\b(prefer|likes?|wants?|always|first|before|ask)\b", t):
        return "preference"
    return default
