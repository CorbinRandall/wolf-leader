"""Project progress, goals, build prompts, and unfiled sessions."""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from ide_storage.db import db_conn


def _project(slug: str) -> int:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO projects (name, path, slug, description, status, created_at, updated_at) "
            "VALUES (?, '', ?, ?, 'active', '2026-01-01T00:00:00', '2026-01-01T00:00:00')",
            (slug.title(), slug, f"About {slug}."),
        )
        conn.commit()
        cur.execute("SELECT id FROM projects WHERE slug = ?", (slug,))
        return int(cur.fetchone()["id"])


def _memory(project_id: int, kind: str, content: str) -> int:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO memories (project_id, type, content, created_at, updated_at) VALUES (?, ?, ?, 'now', 'now')",
            (project_id, kind, content),
        )
        conn.commit()
        cur.execute("SELECT MAX(id) AS id FROM memories")
        return int(cur.fetchone()["id"])


def _chat(project_id: int | None, title: str) -> int:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO chats (title, project_id, status, created_at, updated_at) VALUES (?, ?, 'archived', '2026-02-01T00:00:00', '2026-02-01T00:00:00')",
            (title, project_id),
        )
        conn.commit()
        cur.execute("SELECT MAX(id) AS id FROM chats")
        return int(cur.fetchone()["id"])


def test_next_step_comes_from_a_goal_then_from_notes():
    from ide_storage.progress import create_goal, progress_overview

    fans, ideas = _project("fans"), _project("ideas")
    note = _memory(fans, "active_work", "Tune the rear fan curve for the drive cage.")
    _memory(fans, "problem", "Front fans stall below 20 percent.")

    by = {p["slug"]: p for p in progress_overview()["projects"]}
    assert by["fans"]["next_step"] == {"text": "Tune the rear fan curve for the drive cage.", "done_when": "", "from": "notes", "memory_id": note}
    assert by["fans"]["open_problems"][0]["text"] == "Front fans stall below 20 percent."
    assert by["fans"]["where_it_stands"] == "About fans."
    assert by["ideas"]["next_step"] is None

    goal = create_goal(fans, "Quiet the drive cage", done_when="Under 35 dB at idle for an hour", source_memory_id=note)
    by = {p["slug"]: p for p in progress_overview()["projects"]}
    assert by["fans"]["next_step"]["from"] == "goal" and by["fans"]["next_step"]["goal_id"] == goal["id"]
    # A note that became a goal is no longer offered as a suggestion.
    assert by["fans"]["suggestions"] == []
    assert by["fans"]["goal_counts"] == {"proposed": 1, "committed": 0, "verified": 0}


def test_a_goal_cannot_be_verified_without_saying_what_was_seen():
    from ide_storage.progress import create_goal, list_goals, update_goal

    pid = _project("fans")
    goal = create_goal(pid, "  Quiet   the drive cage ", phase="next")
    assert goal["title"] == "Quiet the drive cage"

    with pytest.raises(ValueError, match="proves it"):
        update_goal(goal["id"], {"status": "verified"})
    done = update_goal(goal["id"], {"status": "verified", "proof": "Measured 33 dB for an hour on 10/12."})
    assert (done["status"], done["phase"]) == ("verified", "next")

    with pytest.raises(ValueError):
        create_goal(pid, "x", phase="someday")
    with pytest.raises(ValueError):
        create_goal(pid, "   ")
    # "now" goals come first; verified ones sink within their phase.
    first = create_goal(pid, "First thing")
    assert [g["id"] for g in list_goals(pid)] == [first["id"], goal["id"]]


def test_build_prompt_is_scoped_frozen_and_commits_its_goals():
    from ide_storage.progress import build_prompt, create_goal, list_build_prompts, list_goals, update_goal

    pid = _project("fans")
    _memory(pid, "constraint", "Never run the pump below 30 percent.")
    _memory(pid, "decision", "Use the BMC for fan control, not the OS.")
    wanted = create_goal(pid, "Quiet the drive cage", done_when="Under 35 dB at idle")
    other = create_goal(pid, "Repaint the case")

    prompt = build_prompt(pid, [wanted["id"]], note="Do not touch the GPU curve.", public_url="http://hub.example")
    body = prompt["body"]

    assert "# Build brief: Fans" in body
    assert "**Quiet the drive cage**" in body and "Done when: Under 35 dB at idle" in body
    assert "Repaint the case" not in body
    assert "Never run the pump below 30 percent." in body and "Use the BMC for fan control" in body
    assert "Do not touch the GPU curve." in body
    assert "/wolfeat for `fans`" in body and "/wolfhowl" in body
    statuses = {g["id"]: g["status"] for g in list_goals(pid)}
    assert statuses == {wanted["id"]: "committed", other["id"]: "proposed"}

    # The saved prompt stays as written when the goal changes later.
    update_goal(wanted["id"], {"title": "Silence the drive cage"})
    assert "**Quiet the drive cage**" in list_build_prompts(pid)[0]["body"]

    with pytest.raises(ValueError, match="at least one goal"):
        build_prompt(pid, [])


def test_unfiled_sessions_can_be_filed():
    from ide_storage.progress import file_session, progress_overview, unfiled_sessions

    pid = _project("fans")
    _chat(pid, "Filed already")
    loose = _chat(None, "Poking at fan headers")

    assert [s["title"] for s in unfiled_sessions()] == ["Poking at fan headers"]
    assert progress_overview()["unfiled_sessions"] == 1

    assert file_session(loose, pid)["project_name"] == "Fans"
    assert unfiled_sessions() == []
    with pytest.raises(LookupError):
        file_session(loose, 999999)


def test_progress_routes():
    from ide_storage.main import app

    client = TestClient(app)
    pid = _project("fans")

    goal = client.post(f"/api/projects/{pid}/goals", json={"title": "Quiet the cage", "done_when": "Under 35 dB"}).json()
    assert goal["status"] == "proposed"
    assert client.put(f"/api/goals/{goal['id']}", json={"status": "verified"}).status_code == 400
    assert client.put(f"/api/goals/{goal['id']}", json={"phase": "later"}).json()["phase"] == "later"
    assert client.get("/api/progress").json()["projects"][0]["goals"][0]["title"] == "Quiet the cage"

    prompt = client.post(f"/api/projects/{pid}/build-prompts", json={"goal_ids": [goal["id"]]}).json()
    assert "Quiet the cage" in prompt["body"]
    assert client.get(f"/api/projects/{pid}/build-prompts").json()["prompts"][0]["id"] == prompt["id"]
    assert client.post("/api/projects/999999/goals", json={"title": "x"}).status_code == 404

    assert client.delete(f"/api/goals/{goal['id']}").json()["ok"] is True
    assert client.get("/api/sessions/unfiled").json() == {"sessions": []}


def test_auto_file_moves_only_confident_matches(monkeypatch):
    from ide_storage import project_match
    from ide_storage.progress import auto_file_sessions, unfiled_sessions

    pid = _project("fans")
    clear, vague = _chat(None, "Fan curve for the drive cage"), _chat(None, "Unzip these files")

    def fake_match(text, **_):
        if "Fan curve" in text:
            return {"project_id": pid, "confidence": "high"}
        return {"project_id": pid, "confidence": "medium"}

    monkeypatch.setattr(project_match, "best_project_match", fake_match)

    result = auto_file_sessions()

    assert [f["chat_id"] for f in result["filed"]] == [clear]
    assert result["left_loose"] == 1
    assert [s["id"] for s in unfiled_sessions()] == [vague]
