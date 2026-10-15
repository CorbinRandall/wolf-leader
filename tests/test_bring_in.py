"""Bring in from any AI chatbot: one prompt out, its answer pasted back."""
from __future__ import annotations

import json

from fastapi.testclient import TestClient

ANSWER = "Here you go!\n```json\n" + json.dumps({
    "about_me": [{"kind": "style", "text": "I like plain answers."}, "I make music at home."],
    "projects": [
        {"name": "Garden Planner", "what": "Planning a vegetable garden.", "status": "active",
         "north_star": "Fresh vegetables all summer", "when": "Spring 2026",
         "notes": [{"type": "decision", "text": "Raised beds, not rows."}, {"type": "mood", "text": "Fun so far."}]},
        {"name": "One-offs", "what": "", "notes": [{"type": "note", "text": "Asked about a fish tank heater."}]},
    ],
}) + ",\n```\nAnything else?"


def test_answer_is_previewed_then_saved(monkeypatch):
    from ide_storage import owners
    from ide_storage.main import app

    monkeypatch.setenv("WOLF_OWNERS", "Dee")
    owners._cache.update(at=0.0, owners=None)
    client = TestClient(app)
    assert "JSON" in client.get("/api/bring-in/prompt").json()["prompt"]
    assert client.post("/api/bring-in/preview", json={"text": "no idea"}).status_code == 400

    found = client.post("/api/bring-in/preview", json={"text": ANSWER}).json()
    assert [i["text"] for i in found["about_me"]] == ["I like plain answers.", "I make music at home."]
    garden, one_offs = found["projects"]
    assert garden["match"] is None and garden["status"] == "in_progress"
    assert [n["type"] for n in garden["notes"]] == ["decision", "note"]  # unknown types become notes
    assert one_offs["match"]["name"] == "One-offs"

    garden["choice"], one_offs["choice"] = "new", "one-offs"
    done = client.post("/api/bring-in/apply", json={"person": "Dee", "source": "chatgpt",
                                                     "about_me": found["about_me"], "projects": [garden, one_offs]}).json()
    assert done["profile_added"] == 2 and done["projects_made"] == ["Garden Planner"] and done["memories"] == 3
    projects = {p["name"]: p for p in client.get("/api/projects?limit=1000").json()["projects"]}
    assert "Garden Planner" in projects and "One-offs" in projects
    # The same answer again finds the project it made.
    again = client.post("/api/bring-in/preview", json={"text": ANSWER}).json()
    assert again["projects"][0]["match"]["name"] == "Garden Planner"
    owners._cache.update(at=0.0, owners=None)


def test_profile_answer_from_any_ai(monkeypatch):
    from ide_storage import owners
    from ide_storage.main import app

    monkeypatch.setenv("WOLF_OWNERS", "Eve")
    owners._cache.update(at=0.0, owners=None)
    client = TestClient(app)
    assert "JSON array" in client.get("/api/people/Eve/profile/prompt").json()["prompt"]
    items = client.post("/api/profile/read", json={"text": '```json\n[{"kind":"tools","text":"I use a Mac."}]\n```'}).json()["items"]
    assert items == [{"kind": "tools", "text": "I use a Mac.", "source": "ai"}]
    assert client.post("/api/profile/read", json={"text": "sorry"}).status_code == 400
    owners._cache.update(at=0.0, owners=None)
