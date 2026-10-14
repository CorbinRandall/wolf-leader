"""People's profiles: kept in one place, edited by hand, and read by every AI tool."""
from __future__ import annotations

from fastapi.testclient import TestClient

from ide_storage.profiles import guess_kind, items_from_text


def test_profile_items_are_added_edited_and_removed(monkeypatch):
    from ide_storage import owners
    from ide_storage.main import app

    monkeypatch.setenv("WOLF_OWNERS", "Ann,Bo")
    owners._cache.update(at=0.0, owners=None)
    client = TestClient(app)

    item = client.post("/api/people/ann/profile", json={"text": "Keep replies short and plain.", "kind": "style"}).json()
    assert (item["person"], item["kind"], item["source"]) == ("Ann", "style", "manual")
    # The same statement twice is kept once.
    assert client.post("/api/people/Ann/profile", json={"text": "keep replies short and plain."}).json()["id"] == item["id"]
    assert client.post("/api/people/Nobody/profile", json={"text": "x x x x x x x"}).status_code == 404
    assert client.post("/api/people/Ann/profile", json={"text": "Hello there", "kind": "mood"}).status_code == 400

    edited = client.put(f"/api/profile-items/{item['id']}", json={"text": "Keep replies short."}).json()
    assert edited["text"] == "Keep replies short."
    profile = client.get("/api/people/Ann/profile").json()
    assert profile["count"] == 1
    assert [s["title"] for s in profile["sections"] if s["items"]] == ["How I like answers written"]
    assert "- Keep replies short." in client.get("/api/people/Ann/profile.md").text

    imported = client.post("/api/people/Ann/profile/import", json={"items": [
        {"text": "Uses a Mac and an Unraid server.", "kind": "tools", "source": "claude"},
        {"text": "Keep replies short.", "kind": "style"},
        {"text": " ", "kind": "about"},
    ]}).json()
    assert imported == {"added": 1, "count": 2}

    assert client.delete(f"/api/profile-items/{item['id']}").json()["ok"] is True
    assert client.get("/api/people/Ann/profile").json()["count"] == 1
    owners._cache.update(at=0.0, owners=None)


def test_memory_and_rules_files_become_profile_items():
    text = """---
name: talk-simply
metadata:
  type: feedback
---

Corbin wants every reply short and plain.

- Never dump file paths unless asked.
- Prefers to try changes in dev before production.

**Why:** Long reports were hard to follow.
"""
    items = items_from_text(text, "claude")
    assert [(i["text"], i["kind"]) for i in items] == [
        ("Corbin wants every reply short and plain.", "style"),
        ("Never dump file paths unless asked.", "avoid"),
        ("Prefers to try changes in dev before production.", "preference"),
    ]
    assert all(i["source"] == "claude" for i in items)
    assert guess_kind("Runs everything on an Unraid server") == "tools"


def test_known_sessions_lets_an_import_skip_what_is_already_saved():
    from ide_storage.db import db_conn
    from ide_storage.main import app

    with db_conn() as conn:
        conn.execute("INSERT INTO chats (title, session_id, status, created_at, updated_at) VALUES ('x', 'abc', 'archived', 'now', 'now')")
        conn.commit()
    assert TestClient(app).post("/api/sessions/known", json={"ids": ["abc", "zzz"]}).json() == {"known": ["abc"]}
