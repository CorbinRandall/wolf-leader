"""Project progress: where each project stands, its goals, and build prompts for an agent.

Everything here is read from what the journal already holds (the latest session
summary and typed memories), plus two small things the person adds: goals, and
the prompts built from them. A prompt is frozen when it is made, so it stays the
exact brief that was handed over even after the project moves on.
"""
from __future__ import annotations

import json
from datetime import datetime
from typing import Any

from ide_storage.db import db_conn

PHASES = ("now", "next", "later")
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


def create_goal(
    project_id: int, title: str, *, done_when: str = "", phase: str = "now",
    status: str = "proposed", source_memory_id: int | None = None,
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
            INSERT INTO goals (project_id, title, done_when, phase, status, proof, source_memory_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, '', ?, ?, ?)
            """,
            (project_id, title[:300], (done_when or "").strip()[:600], phase, status, source_memory_id, now, now),
        )
        goal_id = int(cur.lastrowid)
        conn.commit()
        cur.execute("SELECT * FROM goals WHERE id = ?", (goal_id,))
        return _goal(dict(cur.fetchone()))


def update_goal(goal_id: int, changes: dict[str, Any]) -> dict[str, Any]:
    allowed = {k: v for k, v in changes.items() if k in ("title", "done_when", "phase", "status", "proof") and v is not None}
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
    out: list[dict[str, Any]] = []
    with db_conn() as conn:
        cur = conn.cursor()
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
                "where_it_stands": _clip(left.get("summary") or left.get("human_summary") or row.get("description"), 320),
                "last_session": row.get("last_session") or row.get("updated_at"),
                "sessions": int(row.get("sessions") or 0), "memories": int(row.get("memories") or 0),
                "next_step": next_step,
                "open_problems": [{"id": m["id"], "text": _clip(m["content"], 200)} for m in problems],
                "suggestions": [{"memory_id": m["id"], "text": _clip(m["content"], 220), "type": m["type"]} for m in suggestions],
                "goals": goals,
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
    lines += ["## Build this", ""]
    for i, goal in enumerate(goals, 1):
        lines.append(f"{i}. **{goal['title']}**")
        if goal["done_when"]:
            lines.append(f"   Done when: {goal['done_when']}")
    lines += ["", "Build only what is listed. If something else looks necessary, say so and stop instead of widening the scope.", ""]
    if note.strip():
        lines += ["## Notes from the owner", "", note.strip(), ""]
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
