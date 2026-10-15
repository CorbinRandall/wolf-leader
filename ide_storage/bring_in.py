"""Bring in from any AI chatbot with one prompt.

ChatGPT, Claude, Gemini and the rest can each recall the person and their past chats, but none
lets another app read that history. So, like Claude's own memory import, the person pastes a
prompt into the chatbot, then pastes its answer back here. The answer is already distilled: who
they are, and each project with its key decisions. Nothing is saved until they confirm.
"""
from __future__ import annotations

import json
import re
from typing import Any

from ide_storage.db import MEMORY_TYPES, db_conn

PROMPT = """I'm moving my AI history into Wolf Leader, the app where I keep my projects. Using your memory of me and our past conversations (search them if you can), write down everything useful you know.

Answer with one JSON code block and nothing else, in this shape:

{
  "about_me": [
    {"kind": "about", "text": "..."}
  ],
  "projects": [
    {
      "name": "Short project name",
      "what": "One or two sentences on what it is",
      "status": "active",
      "north_star": "Where it is heading, if known",
      "when": "Roughly when we worked on it",
      "notes": [
        {"type": "decision", "text": "..."}
      ]
    }
  ]
}

Rules:
- about_me: up to 15 short first-person sentences ("I ..."). kind is one of about, preference (how I like to work), style (how I like answers written), tools (devices, apps, services I use), avoid (things you should not do).
- projects: everything we worked on more than once, newest first. Anything we did only once goes in one project named "One-offs".
- status is active, done, or idea. notes: up to 8 per project; type is decision, goal, problem, constraint, or note. One sentence each.
- Leave out passwords, keys, account numbers, addresses, and other people's private details.
- If you can't see past conversations, use what you remember and say nothing else."""

STATUS = {"active": "in_progress", "in progress": "in_progress", "done": "done", "finished": "done",
          "idea": "backlog", "paused": "done"}
KINDS = ("about", "preference", "style", "tools", "avoid")


def _json_object(text: str) -> dict[str, Any] | None:
    """The JSON in a chatbot's answer: inside a code fence or not, with some slack."""
    text = (text or "").strip()
    fence = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.S)
    candidates = [fence.group(1)] if fence else []
    start, end = text.find("{"), text.rfind("}")
    if start >= 0 and end > start:
        candidates.append(text[start:end + 1])
    for raw in candidates:
        for attempt in (raw, re.sub(r",\s*([}\]])", r"\1", raw)):  # trailing commas are common
            try:
                data = json.loads(attempt)
            except json.JSONDecodeError:
                continue
            if isinstance(data, dict):
                return data
    return None


def _clean(value: Any, limit: int = 600) -> str:
    return " ".join(str(value or "").split())[:limit]


def _match(name: str, what: str, projects: list[dict[str, Any]]) -> dict[str, Any] | None:
    """An existing project with the same name, or a confident match on what it is about."""
    from ide_storage.project_match import ONE_OFFS_SLUG, score_project_matches

    key = re.sub(r"[^a-z0-9]", "", name.lower())
    if key == "oneoffs":
        hit = next((p for p in projects if p["slug"] == ONE_OFFS_SLUG), None)
        return {"project_id": hit["id"], "name": hit["name"]} if hit else {"project_id": None, "name": "One-offs", "one_offs": True}
    for p in projects:
        if key and key in (re.sub(r"[^a-z0-9]", "", (p["name"] or "").lower()), re.sub(r"[^a-z0-9]", "", p["slug"] or "")):
            return {"project_id": p["id"], "name": p["name"]}
    try:
        ranked = score_project_matches(f"{name}\n{what}")
    except Exception:  # noqa: BLE001
        ranked = []
    if ranked and ranked[0].get("confidence") == "high":
        return {"project_id": ranked[0]["project_id"], "name": ranked[0].get("name")}
    return None


def preview(text: str) -> dict[str, Any]:
    """Read a chatbot's answer into what would be added. Saves nothing."""
    data = _json_object(text)
    if data is None:
        raise ValueError("That doesn't look like the answer to the prompt. Paste the whole reply, including the code block.")
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, name, slug FROM projects")
        projects = [dict(r) for r in cur.fetchall()]
    about = []
    for item in data.get("about_me") or []:
        if isinstance(item, str):
            item = {"text": item}
        text_ = _clean(item.get("text") if isinstance(item, dict) else "", 300)
        if text_:
            kind = item.get("kind") if item.get("kind") in KINDS else "about"
            about.append({"kind": kind, "text": text_})
    out_projects = []
    for raw in data.get("projects") or []:
        if not isinstance(raw, dict) or not _clean(raw.get("name")):
            continue
        name, what = _clean(raw.get("name"), 120), _clean(raw.get("what"))
        notes = []
        for note in raw.get("notes") or []:
            if isinstance(note, str):
                note = {"text": note}
            body = _clean(note.get("text") if isinstance(note, dict) else "", 400)
            if body:
                kind = note.get("type") if note.get("type") in MEMORY_TYPES else "note"
                notes.append({"type": kind, "text": body})
        out_projects.append({
            "name": name, "what": what, "north_star": _clean(raw.get("north_star"), 400), "when": _clean(raw.get("when"), 80),
            "status": STATUS.get(_clean(raw.get("status")).lower(), "in_progress"), "notes": notes[:12],
            "match": _match(name, what, projects),
        })
    return {"about_me": about[:20], "projects": out_projects}


def apply(person: str, source: str, about_me: list[dict[str, Any]], projects: list[dict[str, Any]]) -> dict[str, Any]:
    """Save what the person kept. Each project's `choice` is existing (with project_id), new, or skip."""
    from ide_storage import hub
    from ide_storage.profiles import import_items
    from ide_storage.progress import one_offs_project, set_north_star, start_project, write_journal

    label = {"chatgpt": "ChatGPT", "claude": "Claude", "gemini": "Gemini"}.get(source, source or "another AI")
    added_profile = 0
    if person and about_me:
        added_profile = import_items(person, [{**i, "source": source if source in ("chatgpt", "claude") else "import"}
                                              for i in about_me])["added"]
    made, updated, memories = [], [], 0
    for p in projects:
        choice = p.get("choice") or "skip"
        if choice == "skip":
            continue
        if choice == "one-offs":
            project_id = int(one_offs_project()["id"])
        elif choice == "new":
            created = start_project(p["name"], description=p.get("what") or "", north_star=p.get("north_star") or "",
                                    status=p.get("status") or "in_progress")
            project_id = int(created["id"])
            made.append(p["name"])
        else:
            project_id = int(p.get("project_id") or 0)
            if not project_id:
                continue
            updated.append(p["name"])
            if (p.get("north_star") or "").strip():
                try:
                    from ide_storage.progress import north_star

                    if not north_star(project_id)["current"]:
                        set_north_star(project_id, p["north_star"], f"Brought in from {label}.")
                except Exception:  # noqa: BLE001
                    pass
        summary = f"Brought in from {label}" + (f" ({p['when']})" if p.get("when") else "") + "."
        if p.get("what"):
            summary += f"\n\n{p['what']}"
        if choice != "one-offs" or p.get("what"):
            write_journal(project_id, summary, title=f"From {label}: {p['name']}")
        for note in p.get("notes") or []:
            try:
                hub.remember(project_id, note.get("type") or "note", note["text"])
                memories += 1
            except (ValueError, KeyError):
                continue
    return {"profile_added": added_profile, "projects_made": made, "projects_updated": updated, "memories": memories}
