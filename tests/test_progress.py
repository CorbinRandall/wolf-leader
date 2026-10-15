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


def test_north_star_changes_are_kept_as_history():
    from ide_storage.progress import build_prompt, create_goal, north_star, progress_overview, set_north_star

    pid = _project("media")
    assert north_star(pid) == {"current": None, "history": [], "changes": 0}

    set_north_star(pid, "Publish one video a day.", created_at="2026-09-01T00:00:00")
    set_north_star(pid, "Publish one video a day.", created_at="2026-09-02T00:00:00")  # same text: no new version
    star = set_north_star(pid, "Find one repeatable format each day.", "Daily posting was the wrong target.",
                          created_at="2026-09-25T00:00:00")

    assert star["current"]["body"] == "Find one repeatable format each day."
    assert star["current"]["why"] == "Daily posting was the wrong target."
    assert [h["body"] for h in star["history"]] == ["Publish one video a day."]
    assert star["changes"] == 1
    assert {p["slug"]: p["north_star"] for p in progress_overview()["projects"]}["media"] == star["current"]["body"]

    goal = create_goal(pid, "Daily trend brief")
    assert "## North Star\n\nFind one repeatable format each day." in build_prompt(pid, [goal["id"]])["body"]

    cleared = set_north_star(pid, "", created_at="2026-10-01T00:00:00")
    assert cleared["current"] is None and len(cleared["history"]) == 2


def test_north_stars_are_lifted_from_the_journal_once():
    from ide_storage.progress import north_star, seed_north_stars

    pid = _project("media")
    other = _project("fans")
    first = _memory(pid, "goal", "North star: publish one original vertical music video per day.")
    _memory(pid, "goal", "North star revised on 2026-09-25: every day identify one repeatable format.")
    _memory(pid, "note", "The north star came up in passing.")

    assert seed_north_stars() == 2
    star = north_star(pid)
    assert star["current"]["body"] == "every day identify one repeatable format."
    assert [h["body"] for h in star["history"]] == ["publish one original vertical music video per day."]
    assert north_star(other)["current"] is None
    assert seed_north_stars() == 0  # already has one; nothing is added twice
    assert first


def test_milestones_order_goals_and_survive_being_removed():
    from fastapi.testclient import TestClient

    from ide_storage.main import app
    from ide_storage.progress import build_prompt, list_goals

    client = TestClient(app)
    pid = _project("media")

    style = client.post(f"/api/projects/{pid}/milestones", json={"title": "Lock the art style"}).json()
    clips = client.post(f"/api/projects/{pid}/milestones", json={"title": "Turn stills into clips"}).json()
    assert (style["position"], clips["position"], style["status"]) == (1, 2, "not_started")
    assert client.post(f"/api/projects/{pid}/milestones", json={"title": " "}).status_code == 400

    goal = client.post(f"/api/projects/{pid}/goals", json={"title": "Five approved stills", "milestone_id": style["id"]}).json()
    loose = client.post(f"/api/projects/{pid}/goals", json={"title": "Tidy the folder"}).json()
    assert (goal["milestone_id"], loose["milestone_id"]) == (style["id"], None)
    assert "Part of the milestone: Lock the art style" in build_prompt(pid, [goal["id"]])["body"]

    assert client.put(f"/api/milestones/{style['id']}", json={"status": "done"}).json()["status"] == "done"
    assert client.put(f"/api/milestones/{style['id']}", json={"status": "someday"}).status_code == 400
    order = client.put(f"/api/projects/{pid}/milestones/order", json={"ids": [clips["id"], style["id"]]}).json()["milestones"]
    assert [m["title"] for m in order] == ["Turn stills into clips", "Lock the art style"]

    project = next(p for p in client.get("/api/progress").json()["projects"] if p["project_id"] == pid)
    assert [m["title"] for m in project["milestones"]] == ["Turn stills into clips", "Lock the art style"]

    assert client.put(f"/api/goals/{loose['id']}", json={"milestone_id": clips["id"]}).json()["milestone_id"] == clips["id"]
    assert client.put(f"/api/goals/{loose['id']}", json={"milestone_id": 0}).json()["milestone_id"] is None

    # Removing a milestone keeps its goals.
    assert client.delete(f"/api/milestones/{style['id']}").json()["ok"] is True
    assert {g["id"]: g["milestone_id"] for g in list_goals(pid)}[goal["id"]] is None


def test_a_project_can_be_started_and_written_in_without_an_agent(monkeypatch):
    from fastapi.testclient import TestClient

    from ide_storage.main import app
    from ide_storage.progress import list_milestones, north_star

    monkeypatch.setenv("WOLF_WIKI_ENABLED", "0")
    client = TestClient(app)
    _project("album")  # takes the slug, so the new one gets the next free one

    made = client.post("/api/projects/start", json={
        "name": "Album", "description": "Ten songs made with AI tools.",
        "north_star": "Release a ten-song album I would play for friends.",
        "status": "in_progress", "milestones": ["Pick the sound", " ", "Write ten songs"],
        "folder": "/work/album", "tags": ["music", " "],
    }).json()
    assert made["slug"] == "album-2"
    pid = made["id"]
    assert north_star(pid)["current"]["body"] == "Release a ten-song album I would play for friends."
    assert [m["title"] for m in list_milestones(pid)] == ["Pick the sound", "Write ten songs"]
    project = client.get(f"/api/projects/{pid}").json()
    assert (project["status"], project["description"]) == ("in_progress", "Ten songs made with AI tools.")
    assert [p["path"] for p in client.get(f"/api/projects/{pid}/paths").json()] == ["/work/album"]
    assert client.post("/api/projects/start", json={"name": "  "}).status_code == 400

    entry = client.post(f"/api/projects/{pid}/journal", json={"text": "Decided to keep every song under three minutes."}).json()
    assert entry["ok"] is True
    chats = client.get(f"/api/projects/{pid}/chats", params={"archived": "true"}).json()
    titles = [c["title"] for c in chats.get("archived", []) + chats.get("active", [])]
    assert "Decided to keep every song under three minutes." in titles
    assert client.post(f"/api/projects/{pid}/journal", json={"text": " "}).status_code == 400
