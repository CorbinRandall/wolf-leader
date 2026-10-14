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
SOURCES = ("manual", "claude", "codex", "cursor", "chatgpt", "journal", "import", "history", "ai")


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


# --- Written from history -------------------------------------------------------------------
# Like Hermes Agent's USER.md, a profile stays short (a page, not a dossier) and every line is
# proposed, then kept or dropped by the person. Wolf Leader already holds their chats, so nobody
# should have to type it up.

# Without an AI, only clear statements about the person count: they start with one of these.
_STATEMENT = re.compile(
    r"^(?:i (?:really |always |usually )?(?:prefer|like|love|hate|don't like|do not like|care about|tend to|"
    r"work best|usually)|i'd (?:rather|prefer)|please (?:don't|do not|never|always|keep)|"
    r"(?:don't|never) (?:ever )?(?:use|add|change|delete|make|write|assume|push|deploy)|always (?:ask|use|keep|check)|"
    r"i'm (?:a|an|new to|not a)\b|i am (?:a|an|new to|not a)\b)", re.I)
_CUE = re.compile(
    r"\b(i prefer|i'd prefer|i like|i love|i hate|i don't like|i do not like|i want you to|i'd rather|"
    r"please don't|please do not|don't ever|never|always|i'm (?:a|an|not|new|trying)|i am (?:a|an|not|new)|"
    r"i work|i usually|i tend to|my goal|i care about|i'm building|i'm making)\b", re.I)
_TOOLS = ("Mac", "Windows", "iPhone", "Linux", "Unraid", "Proxmox", "Docker", "Tailscale", "Home Assistant",
          "Plex", "Immich", "Nextcloud", "Cursor", "Codex", "Claude Code", "ChatGPT", "VS Code", "Xcode",
          "Ableton", "Logic Pro", "Figma", "Notion", "GitHub", "Python", "Swift", "TypeScript", "React")


def _people_projects(person: str) -> list[dict[str, Any]]:
    """Projects that are this person's: theirs by owner, or everything on a one-person hub."""
    from ide_storage.owners import attach_owners, configured_owners
    from ide_storage.project_match import ONE_OFFS_TAG

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, name, slug, description, status, tags, path, metadata, updated_at FROM projects")
        rows = [dict(r) for r in cur.fetchall()]
    rows = [r for r in rows if ONE_OFFS_TAG not in str(r.get("tags") or "")]
    attach_owners(rows)
    if len(configured_owners()) > 1:
        rows = [r for r in rows if (r.get("owner") or "").lower() == person.lower()]
    return sorted(rows, key=lambda r: r.get("updated_at") or "", reverse=True)


def _user_lines(project_ids: list[int], include_loose: bool, limit: int = 4000) -> list[str]:
    """What the person typed, newest first, pasted logs and walls of text left out."""
    if not project_ids and not include_loose:
        return []
    where = []
    params: list[Any] = []
    if project_ids:
        where.append(f"c.project_id IN ({','.join('?' * len(project_ids))})")
        params += project_ids
    if include_loose:
        where.append("c.project_id IS NULL OR c.project_id IN (SELECT id FROM projects WHERE slug = 'one-offs')")
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            f"""SELECT m.content FROM messages m JOIN chats c ON c.id = m.chat_id
                WHERE m.role = 'user' AND ({' OR '.join(where)}) ORDER BY m.id DESC LIMIT ?""",
            (*params, limit),
        )
        out = []
        for r in cur.fetchall():
            text = (r["content"] or "").strip()
            if 8 <= len(text) <= 1500 and text.count("\n") < 15:
                out.append(" ".join(text.split()))
        return out


def _sentences(text: str) -> list[str]:
    return [s.strip(" -*•") for s in re.split(r"(?<=[.!?])\s+|\n+", text) if s.strip()]


def history_digest(name: str, max_chars: int = 24_000) -> dict[str, Any]:
    """A compact read of someone's history, for an AI tool to write their profile from."""
    from ide_storage.owners import configured_owners

    person = _person(name)
    projects = _people_projects(person)
    lines = _user_lines([int(p["id"]) for p in projects], include_loose=len(configured_owners()) <= 1)
    parts = [f"Person: {person}", "", f"Projects ({len(projects)}):"]
    for p in projects[:40]:
        parts.append(f"- {p['name']} [{p.get('status') or 'active'}]: {(p.get('description') or '')[:160]}")
    current = profile(person)
    if current["count"]:
        parts += ["", "Already in their profile:"] + [f"- {i['text']}" for s in current["sections"] for i in s["items"]]
    cued = [line for line in lines if _CUE.search(line)][:160]
    parts += ["", "Things they said about how they work (newest first):"] + [f"- {line[:300]}" for line in cued]
    parts += ["", "Other things they asked for (newest first):"]
    text = "\n".join(parts)
    for line in lines:
        if line in cued:
            continue
        addition = f"\n- {line[:240]}"
        if len(text) + len(addition) > max_chars:
            break
        text += addition
    return {"person": person, "projects": len(projects), "messages": len(lines), "text": text[:max_chars]}


def suggest_from_history(name: str, limit: int = 15) -> dict[str, Any]:
    """Profile lines found in someone's own words, without any AI: statements about how they like
    to work, the tools they keep mentioning, and what they are working on. They review each one."""
    from ide_storage.owners import configured_owners

    person = _person(name)
    projects = _people_projects(person)
    lines = _user_lines([int(p["id"]) for p in projects], include_loose=len(configured_owners()) <= 1)
    have = {i["text"].lower() for s in profile(person)["sections"] for i in s["items"]}
    seen: dict[str, dict[str, Any]] = {}
    for line in lines:
        for sentence in _sentences(line):
            sentence = re.sub(r"</?[a-z_]+>", "", sentence).strip()
            if not (20 <= len(sentence) <= 180) or not _STATEMENT.match(sentence) or "http" in sentence or "/" in sentence:
                continue
            key = re.sub(r"[^a-z ]", "", sentence.lower())[:80]
            entry = seen.setdefault(key, {"text": sentence[0].upper() + sentence[1:], "kind": guess_kind(sentence), "count": 0})
            entry["count"] += 1
    picked = [e for e in sorted(seen.values(), key=lambda e: -e["count"]) if e["text"].lower() not in have][: limit - 2]
    joined = "\n".join(lines).lower()
    tools = [t for t in _TOOLS if len(re.findall(rf"\b{re.escape(t.lower())}\b", joined)) >= 3]
    extra = []
    if tools:
        extra.append({"text": "I use " + ", ".join(tools[:10]) + ".", "kind": "tools"})
    active = [p["name"] for p in projects
              if (p.get("status") or "") != "done" and "owner-folder" not in str(p.get("tags") or "")][:6]
    if active:
        extra.append({"text": "I'm working on " + ", ".join(active) + ".", "kind": "about"})
    items = [{"text": e["text"], "kind": e["kind"], "source": "history"} for e in extra + picked
             if e["text"].lower() not in have]
    return {"person": person, "items": items[:limit], "looked_at": len(lines)}


from ide_storage.profile_text import guess_kind, items_from_text  # noqa: E402,F401  (re-exported)
