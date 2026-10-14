"""Project progress: where each project stands, its goals, and build prompts for an agent.

Everything here is read from what the journal already holds (the latest session
summary and typed memories), plus two small things the person adds: goals, and
the prompts built from them. A prompt is frozen when it is made, so it stays the
exact brief that was handed over even after the project moves on.
"""
from __future__ import annotations

import json
import re
from datetime import datetime
from typing import Any

from ide_storage.db import db_conn

PHASES = ("now", "next", "later")
MILESTONE_STATES = ("not_started", "in_play", "done")
STATUSES = ("proposed", "committed", "verified")


def _now() -> str:
    return datetime.utcnow().isoformat()


def _clip(text: str | None, limit: int) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def _left_off(raw: Any) -> dict[str, Any]:
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            raw = None
    return raw if isinstance(raw, dict) else {}


def _goal(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": int(row["id"]), "project_id": int(row["project_id"]), "title": row["title"],
        "done_when": row.get("done_when") or "", "phase": row.get("phase") or "now",
        "status": row.get("status") or "proposed", "proof": row.get("proof") or "",
        "milestone_id": row.get("milestone_id"),
        "source_memory_id": row.get("source_memory_id"),
        "created_at": row.get("created_at"), "updated_at": row.get("updated_at"),
    }


def list_goals(project_id: int | None = None) -> list[dict[str, Any]]:
    with db_conn() as conn:
        cur = conn.cursor()
        if project_id is None:
            cur.execute("SELECT * FROM goals ORDER BY id")
        else:
            cur.execute("SELECT * FROM goals WHERE project_id = ? ORDER BY id", (project_id,))
        goals = [_goal(dict(r)) for r in cur.fetchall()]
    order = {p: i for i, p in enumerate(PHASES)}
    goals.sort(key=lambda g: (order.get(g["phase"], 9), g["status"] == "verified", g["id"]))
    return goals


def list_milestones(project_id: int | None = None) -> list[dict[str, Any]]:
    with db_conn() as conn:
        cur = conn.cursor()
        if project_id is None:
            cur.execute("SELECT * FROM milestones ORDER BY project_id, position, id")
        else:
            cur.execute("SELECT * FROM milestones WHERE project_id = ? ORDER BY position, id", (project_id,))
        return [
            {"id": int(r["id"]), "project_id": int(r["project_id"]), "title": r["title"], "position": int(r["position"]),
             "status": r["status"] or "not_started"}
            for r in cur.fetchall()
        ]


def create_milestone(project_id: int, title: str) -> dict[str, Any]:
    title = " ".join((title or "").split())
    if not title:
        raise ValueError("A milestone needs a title")
    now = _now()
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT 1 FROM projects WHERE id = ?", (project_id,))
        if not cur.fetchone():
            raise LookupError("project not found")
        cur.execute("SELECT COALESCE(MAX(position), 0) + 1 AS next FROM milestones WHERE project_id = ?", (project_id,))
        position = int(cur.fetchone()["next"])
        cur.execute(
            "INSERT INTO milestones (project_id, title, position, status, created_at, updated_at) VALUES (?, ?, ?, 'not_started', ?, ?)",
            (project_id, title[:200], position, now, now),
        )
        milestone_id = int(cur.lastrowid)
        conn.commit()
    return next(m for m in list_milestones(project_id) if m["id"] == milestone_id)


def update_milestone(milestone_id: int, changes: dict[str, Any]) -> dict[str, Any]:
    allowed = {k: v for k, v in changes.items() if k in ("title", "status") and v is not None}
    if "status" in allowed and allowed["status"] not in MILESTONE_STATES:
        raise ValueError(f"status is one of {MILESTONE_STATES}")
    if "title" in allowed:
        allowed["title"] = " ".join(str(allowed["title"]).split())[:200]
        if not allowed["title"]:
            raise ValueError("A milestone needs a title")
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT project_id FROM milestones WHERE id = ?", (milestone_id,))
        row = cur.fetchone()
        if not row:
            raise LookupError("milestone not found")
        if allowed:
            sets = ", ".join(f"{k} = ?" for k in allowed)
            cur.execute(f"UPDATE milestones SET {sets}, updated_at = ? WHERE id = ?", (*allowed.values(), _now(), milestone_id))
            conn.commit()
    return next(m for m in list_milestones(int(row["project_id"])) if m["id"] == milestone_id)


def reorder_milestones(project_id: int, ordered_ids: list[int]) -> list[dict[str, Any]]:
    """Put a project's milestones in the given order; any left out keep their order after those."""
    current = [m["id"] for m in list_milestones(project_id)]
    wanted = [i for i in ordered_ids if i in current] + [i for i in current if i not in ordered_ids]
    with db_conn() as conn:
        cur = conn.cursor()
        for position, milestone_id in enumerate(wanted, 1):
            cur.execute("UPDATE milestones SET position = ?, updated_at = ? WHERE id = ?", (position, _now(), milestone_id))
        conn.commit()
    return list_milestones(project_id)


def delete_milestone(milestone_id: int) -> dict[str, Any]:
    """Remove a milestone. Its goals are kept and simply belong to no milestone."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM milestones WHERE id = ?", (milestone_id,))
        removed = cur.rowcount or 0
        conn.commit()
    if not removed:
        raise LookupError("milestone not found")
    return {"ok": True, "id": milestone_id}


def create_goal(
    project_id: int, title: str, *, done_when: str = "", phase: str = "now",
    status: str = "proposed", source_memory_id: int | None = None, milestone_id: int | None = None,
) -> dict[str, Any]:
    title = " ".join((title or "").split())
    if not title:
        raise ValueError("A goal needs a title")
    if phase not in PHASES or status not in STATUSES:
        raise ValueError(f"phase is one of {PHASES}; status is one of {STATUSES}")
    now = _now()
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT 1 FROM projects WHERE id = ?", (project_id,))
        if not cur.fetchone():
            raise LookupError("project not found")
        cur.execute(
            """
            INSERT INTO goals (project_id, title, done_when, phase, status, proof, source_memory_id, milestone_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, '', ?, ?, ?, ?)
            """,
            (project_id, title[:300], (done_when or "").strip()[:600], phase, status, source_memory_id, milestone_id, now, now),
        )
        goal_id = int(cur.lastrowid)
        conn.commit()
        cur.execute("SELECT * FROM goals WHERE id = ?", (goal_id,))
        return _goal(dict(cur.fetchone()))


def update_goal(goal_id: int, changes: dict[str, Any]) -> dict[str, Any]:
    allowed = {k: v for k, v in changes.items() if k in ("title", "done_when", "phase", "status", "proof") and v is not None}
    # milestone_id: a number files the goal under a milestone, 0 takes it out of any.
    if changes.get("milestone_id") is not None:
        allowed["milestone_id"] = int(changes["milestone_id"]) or None
    if "phase" in allowed and allowed["phase"] not in PHASES:
        raise ValueError(f"phase is one of {PHASES}")
    if "status" in allowed and allowed["status"] not in STATUSES:
        raise ValueError(f"status is one of {STATUSES}")
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM goals WHERE id = ?", (goal_id,))
        row = cur.fetchone()
        if not row:
            raise LookupError("goal not found")
        merged = {**dict(row), **allowed}
        # "Verified" is a claim that something was observed, so it has to say what.
        if merged["status"] == "verified" and not (merged.get("proof") or "").strip():
            raise ValueError("Say what you saw that proves it before marking a goal verified")
        if allowed:
            sets = ", ".join(f"{k} = ?" for k in allowed)
            cur.execute(f"UPDATE goals SET {sets}, updated_at = ? WHERE id = ?", (*allowed.values(), _now(), goal_id))
            conn.commit()
        cur.execute("SELECT * FROM goals WHERE id = ?", (goal_id,))
        return _goal(dict(cur.fetchone()))


def delete_goal(goal_id: int) -> dict[str, Any]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM goals WHERE id = ?", (goal_id,))
        removed = cur.rowcount or 0
        conn.commit()
    if not removed:
        raise LookupError("goal not found")
    return {"ok": True, "id": goal_id}


# ------------------------------------------------------------------ starting a project by hand
def _unique_slug(cur, name: str) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:56] or "project"
    slug, n = base, 2
    while True:
        cur.execute("SELECT 1 FROM projects WHERE slug = ?", (slug,))
        if not cur.fetchone():
            return slug
        slug, n = f"{base}-{n}", n + 1


def start_project(
    name: str, *, description: str = "", north_star: str = "", owner: str | None = None, status: str = "in_progress",
    milestones: list[str] | None = None, folder: str = "", tags: list[str] | None = None,
) -> dict[str, Any]:
    """Create a project from the app, with everything that gets it going, no agent needed."""
    from ide_storage.markdown_sync import ensure_project_md_from_db, regenerate_index
    from ide_storage.owners import canonical_owner
    from ide_storage.paths import register_project_path

    name = " ".join((name or "").split())
    if not name:
        raise ValueError("A project needs a name")
    metadata: dict[str, Any] = {"created_from": "app"}
    if owner and owner.strip():
        resolved = canonical_owner(owner)
        if resolved is None:
            raise ValueError(f"Unknown owner: {owner}")
        metadata["owner"] = resolved
    now = _now()
    with db_conn() as conn:
        cur = conn.cursor()
        slug = _unique_slug(cur, name)
        cur.execute(
            """
            INSERT INTO projects (name, path, description, slug, status, tags, created_at, updated_at, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (name[:120], (folder or "").strip(), (description or "").strip() or None, slug, status or "in_progress",
             json.dumps([t.strip() for t in tags if t.strip()]) if tags else None, now, now, json.dumps(metadata)),
        )
        project_id = int(cur.lastrowid)
        conn.commit()
        cur.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
        row = dict(cur.fetchone())
    if (north_star or "").strip():
        set_north_star(project_id, north_star, "Set when the project was started.")
    for title in milestones or []:
        if title.strip():
            create_milestone(project_id, title)
    if (folder or "").strip():
        register_project_path(project_id, folder.strip(), kind="workspace")
    try:
        ensure_project_md_from_db(row)
        regenerate_index()
    except Exception:  # noqa: BLE001  - the project exists either way
        pass
    return {"id": project_id, "slug": slug, "name": row["name"]}


def write_journal(project_id: int, text: str, title: str = "") -> dict[str, Any]:
    """A journal entry written by hand. It goes through the same save as an agent's session, so it
    shows in the logbook, its decisions and problems become memories, and Ask can find it."""
    import uuid

    from ide_storage.save_project import save_project

    text = (text or "").strip()
    if not text:
        raise ValueError("Write something first")
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT slug FROM projects WHERE id = ?", (project_id,))
        row = cur.fetchone()
    if not row:
        raise LookupError("project not found")
    first_line = text.splitlines()[0]
    result = save_project(
        f"journal-{uuid.uuid4()}", project_slug=row["slug"],
        title=(title or "").strip() or _clip(first_line, 80),
        content=text, messages=[{"role": "user", "content": text}], occurred_at=_now(),
    )
    if not result.get("ok"):
        raise ValueError(result.get("error") or "The entry could not be saved")
    return {"ok": True, "chat_id": result.get("chat_id"), "project_id": project_id}


# ------------------------------------------------------------------ North Star
_STAR_NOTE = re.compile(r"^\s*north star(?:\s+(?:revised|changed|updated)(?:\s+on\s+([0-9]{4}-[0-9]{2}-[0-9]{2}))?)?\s*:\s*", re.I)


def north_star(project_id: int) -> dict[str, Any]:
    """The project's current North Star and the versions before it, newest first."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, body, why, created_at FROM north_stars WHERE project_id = ? ORDER BY created_at DESC, id DESC",
                    (project_id,))
        rows = [dict(r) for r in cur.fetchall()]
    current = rows[0] if rows and rows[0]["body"].strip() else None
    return {"current": current, "history": rows[1:] if rows else [], "changes": max(0, len([r for r in rows if r["body"].strip()]) - 1)}


def set_north_star(project_id: int, body: str, why: str = "", *, created_at: str | None = None,
                   source_memory_id: int | None = None) -> dict[str, Any]:
    """Set or change the North Star. The previous one is kept as history; an empty body clears it."""
    body = " ".join((body or "").split())
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT 1 FROM projects WHERE id = ?", (project_id,))
        if not cur.fetchone():
            raise LookupError("project not found")
        cur.execute("SELECT body FROM north_stars WHERE project_id = ? ORDER BY created_at DESC, id DESC LIMIT 1", (project_id,))
        last = cur.fetchone()
        if last and last["body"].strip() == body:
            return north_star(project_id)  # nothing changed
        if not body and not last:
            return north_star(project_id)
        cur.execute(
            "INSERT INTO north_stars (project_id, body, why, source_memory_id, created_at) VALUES (?, ?, ?, ?, ?)",
            (project_id, body[:1200], (why or "").strip()[:600] or None, source_memory_id, created_at or _now()),
        )
        conn.commit()
    return north_star(project_id)


def delete_north_star_version(version_id: int) -> dict[str, Any]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT project_id FROM north_stars WHERE id = ?", (version_id,))
        row = cur.fetchone()
        if not row:
            raise LookupError("version not found")
        cur.execute("DELETE FROM north_stars WHERE id = ?", (version_id,))
        conn.commit()
    return north_star(int(row["project_id"]))


def seed_north_stars() -> int:
    """Lift North Stars the journal already recorded ("North star: …", "North star revised on …: …").

    Only for projects that have none yet, oldest first, so the changes show up as history.
    """
    seeded = 0
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT m.id, m.project_id, m.content, m.created_at FROM memories m
            WHERE m.project_id IS NOT NULL AND lower(m.content) LIKE 'north star%'
              AND NOT EXISTS (SELECT 1 FROM north_stars n WHERE n.project_id = m.project_id)
            ORDER BY m.created_at, m.id
            """
        )
        notes = [dict(r) for r in cur.fetchall()]
    for note in notes:
        match = _STAR_NOTE.match(note["content"] or "")
        if not match:
            continue
        body = note["content"][match.end():].strip()
        if body:
            # Keep the journal's own order: the date a note was saved, not a date quoted inside it.
            set_north_star(int(note["project_id"]), body, "From the journal.", created_at=note["created_at"],
                           source_memory_id=int(note["id"]))
            seeded += 1
    return seeded


def _memories(cur, project_id: int, kinds: tuple[str, ...], limit: int) -> list[dict[str, Any]]:
    marks = ",".join("?" * len(kinds))
    cur.execute(
        f"""
        SELECT id, type, content, updated_at FROM memories
        WHERE project_id = ? AND type IN ({marks})
        ORDER BY updated_at DESC, id DESC LIMIT ?
        """,
        (project_id, *kinds, limit),
    )
    return [dict(r) for r in cur.fetchall()]


def progress_overview() -> dict[str, Any]:
    """Every active project: where it stands, what is open, and the next useful step."""
    goals_by_project: dict[int, list[dict[str, Any]]] = {}
    for goal in list_goals():
        goals_by_project.setdefault(goal["project_id"], []).append(goal)
    milestones_by_project: dict[int, list[dict[str, Any]]] = {}
    for milestone in list_milestones():
        milestones_by_project.setdefault(milestone["project_id"], []).append(milestone)
    out: list[dict[str, Any]] = []
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT DISTINCT ON (project_id) project_id, body FROM north_stars ORDER BY project_id, created_at DESC, id DESC")
        stars = {int(r["project_id"]): r["body"] for r in cur.fetchall() if (r["body"] or "").strip()}
        cur.execute(
            """
            SELECT r.id, r.slug, r.name, r.description, r.status, r.left_off, r.updated_at,
                   (SELECT COUNT(*) FROM memories m WHERE m.project_id = r.id) AS memories,
                   (SELECT COUNT(*) FROM chats c WHERE c.project_id = r.id) AS sessions,
                   (SELECT MAX(COALESCE(c.occurred_at, c.created_at)) FROM chats c WHERE c.project_id = r.id) AS last_session
            FROM v_project_recall r
            WHERE COALESCE(r.status, 'active') != 'archived'
            """
        )
        rows = [dict(r) for r in cur.fetchall()]
        for row in rows:
            pid = int(row["id"])
            left = _left_off(row.get("left_off"))
            goals = goals_by_project.get(pid, [])
            open_goals = [g for g in goals if g["status"] != "verified"]
            problems = _memories(cur, pid, ("problem",), 3)
            active = _memories(cur, pid, ("active_work", "goal"), 4)
            taken = {g["source_memory_id"] for g in goals if g["source_memory_id"]}
            suggestions = [m for m in active if m["id"] not in taken]
            next_goal = next((g for g in open_goals if g["phase"] == "now"), None) or (open_goals[0] if open_goals else None)
            if next_goal:
                next_step = {"text": next_goal["title"], "done_when": next_goal["done_when"], "from": "goal", "goal_id": next_goal["id"]}
            elif suggestions:
                next_step = {"text": _clip(suggestions[0]["content"], 220), "done_when": "", "from": "notes",
                             "memory_id": suggestions[0]["id"]}
            else:
                next_step = None
            out.append({
                "project_id": pid, "slug": row["slug"], "name": row["name"], "description": row.get("description") or "",
                "status": row.get("status") or "active",
                "north_star": stars.get(pid, ""),
                "where_it_stands": _clip(left.get("summary") or left.get("human_summary") or row.get("description"), 320),
                "last_session": row.get("last_session") or row.get("updated_at"),
                "sessions": int(row.get("sessions") or 0), "memories": int(row.get("memories") or 0),
                "next_step": next_step,
                "open_problems": [{"id": m["id"], "text": _clip(m["content"], 200)} for m in problems],
                "suggestions": [{"memory_id": m["id"], "text": _clip(m["content"], 220), "type": m["type"]} for m in suggestions],
                "goals": goals,
                "milestones": milestones_by_project.get(pid, []),
                "goal_counts": {s: sum(1 for g in goals if g["status"] == s) for s in STATUSES},
            })
        cur.execute("SELECT COUNT(*) AS n FROM chats WHERE project_id IS NULL")
        unfiled = int(cur.fetchone()["n"])
    # Most recently worked on first; projects with a goal in "now" float to the top.
    out.sort(key=lambda p: (not any(g["phase"] == "now" and g["status"] != "verified" for g in p["goals"]),
                            -(datetime.fromisoformat(p["last_session"][:19]).timestamp() if p["last_session"] else 0)))
    return {"projects": out, "unfiled_sessions": unfiled, "phases": list(PHASES), "statuses": list(STATUSES)}


def unfiled_sessions(limit: int = 100) -> list[dict[str, Any]]:
    """Saved sessions that belong to no project yet."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT c.id, c.title, c.workspace_path, c.device_name, c.metadata,
                   COALESCE(c.occurred_at, c.created_at) AS happened_at,
                   (SELECT COUNT(*) FROM messages m WHERE m.chat_id = c.id) AS messages
            FROM chats c WHERE c.project_id IS NULL
            ORDER BY COALESCE(c.occurred_at, c.created_at) DESC LIMIT ?
            """,
            (limit,),
        )
        rows = [dict(r) for r in cur.fetchall()]
    out = []
    for row in rows:
        meta = _left_off(row.pop("metadata", None))
        out.append({**row, "id": int(row["id"]), "messages": int(row["messages"] or 0),
                    "title": _clip(row.get("title") or "Untitled session", 140),
                    "summary": _clip(meta.get("human_summary") or meta.get("agent_summary"), 260)})
    return out


def auto_file_sessions() -> dict[str, Any]:
    """File loose sessions that clearly belong to an existing project. The rest stay loose.

    A session with no project is not an error: one-off questions belong to none. This only
    moves the ones a confident match exists for, so nobody has to sort them by hand.
    """
    from ide_storage.project_match import best_project_match

    filed: list[dict[str, Any]] = []
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, title, workspace_path FROM chats WHERE project_id IS NULL ORDER BY id")
        loose = [dict(r) for r in cur.fetchall()]
        texts: dict[int, str] = {}
        for chat in loose:
            cur.execute("SELECT content FROM messages WHERE chat_id = ? ORDER BY id LIMIT 60", (chat["id"],))
            body = "\n".join((r["content"] or "")[:4000] for r in cur.fetchall())
            texts[chat["id"]] = f"{chat.get('title') or ''}\n{body}"[:80_000]
    for chat in loose:
        try:
            match = best_project_match(texts[chat["id"]], workspace_path=chat.get("workspace_path"))
        except Exception:  # noqa: BLE001
            match = None
        if match and match.get("confidence") == "high" and match.get("project_id"):
            try:
                result = file_session(int(chat["id"]), int(match["project_id"]))
                filed.append({"chat_id": chat["id"], "title": _clip(chat.get("title"), 80), "project": result["project_name"]})
            except LookupError:
                continue
    return {"filed": filed, "left_loose": len(loose) - len(filed)}


def file_session(chat_id: int, project_id: int) -> dict[str, Any]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, name, slug FROM projects WHERE id = ?", (project_id,))
        project = cur.fetchone()
        if not project:
            raise LookupError("project not found")
        cur.execute("UPDATE chats SET project_id = ?, updated_at = ? WHERE id = ?", (project_id, _now(), chat_id))
        if not cur.rowcount:
            raise LookupError("session not found")
        cur.execute("UPDATE memories SET project_id = ? WHERE source_chat_id = ? AND project_id IS NULL", (project_id, chat_id))
        conn.commit()
    return {"ok": True, "chat_id": chat_id, "project_id": project_id, "project_name": project["name"]}


def build_prompt(project_id: int, goal_ids: list[int], *, note: str = "", public_url: str = "") -> dict[str, Any]:
    """A scoped brief for a coding agent: the chosen goals plus the context that bears on them. Saved as written."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM v_project_recall WHERE id = ?", (project_id,))
        row = cur.fetchone()
        if not row:
            raise LookupError("project not found")
        project = dict(row)
        goals = [g for g in list_goals(project_id) if g["id"] in set(goal_ids)]
        if not goals:
            raise ValueError("Choose at least one goal to build")
        constraints = _memories(cur, project_id, ("constraint", "caveat"), 8)
        decisions = _memories(cur, project_id, ("decision",), 8)
        problems = _memories(cur, project_id, ("problem",), 5)
        cur.execute("SELECT path FROM project_paths WHERE project_id = ? ORDER BY id", (project_id,))
        folders = [r["path"] for r in cur.fetchall()]
    left = _left_off(project.get("left_off"))

    def bullets(items: list[dict[str, Any]], limit: int = 260) -> list[str]:
        return [f"- {_clip(m['content'], limit)}" for m in items]

    lines = [f"# Build brief: {project['name']}", ""]
    if project.get("description"):
        lines += [_clip(project["description"], 400), ""]
    star = (north_star(project_id)["current"] or {}).get("body")
    if star:
        lines += ["## North Star", "", star, "",
                  "This is where the project is heading. It can change; if this work suggests it should, say so.", ""]
    lines += ["## Build this", ""]
    milestone_titles = {m["id"]: m["title"] for m in list_milestones(project_id)}
    for i, goal in enumerate(goals, 1):
        lines.append(f"{i}. **{goal['title']}**")
        if goal.get("milestone_id") in milestone_titles:
            lines.append(f"   Part of the milestone: {milestone_titles[goal['milestone_id']]}")
        if goal["done_when"]:
            lines.append(f"   Done when: {goal['done_when']}")
    lines += ["", "Build only what is listed. If something else looks necessary, say so and stop instead of widening the scope.", ""]
    if note.strip():
        lines += ["## Notes from the owner", "", note.strip(), ""]
    owner = _owner_of(project)
    if owner:
        from ide_storage.profiles import as_markdown, profile

        if profile(owner)["count"]:
            body = as_markdown(owner).split("\n", 3)[-1].strip()
            lines += [f"## Working with {owner}", "", body, ""]
    if left.get("summary"):
        lines += ["## Where the project stands", "", _clip(left["summary"], 700), ""]
    if constraints:
        lines += ["## Keep to these", "", *bullets(constraints), ""]
    if decisions:
        lines += ["## Already decided", "", *bullets(decisions), ""]
    if problems:
        lines += ["## Known problems", "", *bullets(problems), ""]
    if folders:
        lines += ["## Where it lives", "", *[f"- `{f}`" for f in folders[:6]], ""]
    lines += [
        "## Before and after",
        "",
        f"- Before you start: run /wolfeat for `{project['slug']}` to load the full project context.",
        "- When you finish: say exactly what you built, what you tested and how, and what you did not verify. "
        "For each goal, state whether its \"done when\" was observed.",
        f"- Then run /wolfhowl so the result is saved to `{project['slug']}`.",
    ]
    if public_url:
        lines.append(f"- Project brief: {public_url.rstrip('/')}/api/projects/{project['slug']}/agent-brief")
    text = "\n".join(lines).rstrip() + "\n"
    now = _now()
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO build_prompts (project_id, goal_ids, title, body, created_at) VALUES (?, ?, ?, ?, ?)",
            (project_id, json.dumps([g["id"] for g in goals]), _clip(goals[0]["title"], 120), text, now),
        )
        prompt_id = int(cur.lastrowid)
        # Handing a goal to an agent is a commitment to it.
        for goal in goals:
            if goal["status"] == "proposed":
                cur.execute("UPDATE goals SET status = 'committed', updated_at = ? WHERE id = ?", (now, goal["id"]))
        conn.commit()
    return {"id": prompt_id, "project_id": project_id, "goal_ids": [g["id"] for g in goals], "title": _clip(goals[0]["title"], 120),
            "body": text, "created_at": now}


def _owner_of(project: dict[str, Any]) -> str | None:
    try:
        from ide_storage.owners import attach_owners

        return attach_owners([dict(project)])[0].get("owner")
    except Exception:  # noqa: BLE001
        return None


def list_build_prompts(project_id: int, limit: int = 20) -> list[dict[str, Any]]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, project_id, goal_ids, title, body, created_at FROM build_prompts WHERE project_id = ? ORDER BY id DESC LIMIT ?",
            (project_id, limit),
        )
        rows = [dict(r) for r in cur.fetchall()]
    for row in rows:
        try:
            row["goal_ids"] = json.loads(row["goal_ids"] or "[]")
        except ValueError:
            row["goal_ids"] = []
    return rows
