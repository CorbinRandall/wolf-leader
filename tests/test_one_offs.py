"""One-offs: the standard home for chats that belong to no project."""
from __future__ import annotations

from fastapi.testclient import TestClient


def test_unmatched_chats_go_to_one_offs_and_never_attract_matches():
    from ide_storage.main import app
    from ide_storage.project_match import score_project_matches

    client = TestClient(app)
    words = "zebrafish aquarium heater thermostat calibration " * 20
    saved = client.post("/api/save-project", json={
        "session_id": "one-off-1", "slug": "one-offs", "title": "Fish tank heater",
        "messages": [{"role": "user", "content": words}, {"role": "assistant", "content": words}],
    }).json()
    assert saved["ok"], saved
    projects = {p["slug"]: p for p in client.get("/api/projects?limit=1000").json()["projects"]}
    assert projects["one-offs"]["name"] == "One-offs"
    # What a one-off chat said must not pull the next chat into One-offs.
    assert all(m.get("slug") != "one-offs" for m in score_project_matches(words))

    client.post("/api/save-project", json={
        "session_id": "loose-1", "title": "Loose question",
        "messages": [{"role": "user", "content": "qwxyz plover " * 30}],
    })
    moved = client.post("/api/sessions/one-offs").json()
    assert moved["project_id"] == projects["one-offs"]["id"]
    assert client.get("/api/sessions/unfiled").json()["sessions"] == []


def test_removed_skill_stays_removed(tmp_path, monkeypatch):
    from ide_storage import skill_registry

    monkeypatch.setenv("IDE_STORAGE_SKILLS_DIR", str(tmp_path / "skills"))
    names = {s["id"] for s in skill_registry.list_skills()}
    assert "wolfhowl" in names
    skill_registry.delete_skill("wolfhowl")
    assert "wolfhowl" not in {s["id"] for s in skill_registry.list_skills()}  # not seeded back
    assert any(p.name.startswith("wolfhowl-") for p in (tmp_path / "skills" / ".trash").iterdir())
    skill_registry.import_skill_files(None, [{"path": "wolfhowl/SKILL.md", "content_base64": "LS0tCm5hbWU6IHdvbGZob3dsCi0tLQo="}], False)
    assert "wolfhowl" in {s["id"] for s in skill_registry.list_skills()}
