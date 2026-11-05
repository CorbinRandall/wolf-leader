"""App chats live whole on the hub so another device can open and continue them."""
from __future__ import annotations

from fastapi.testclient import TestClient


def _client() -> TestClient:
    from ide_storage.main import app

    return TestClient(app)


def _put(client, chat_id, updated, text, device="mac-a"):
    record = {"id": chat_id, "title": text, "agentID": "claude", "items": [{"kind": "user", "text": text}]}
    return client.put(f"/api/app-chats/{chat_id}", json={
        "record": record, "updated": updated, "device": device, "title": text, "agent_id": "claude",
    })


def test_second_device_gets_the_chat_and_its_changes():
    client = _client()
    first = client.get("/api/app-chats").json()
    assert _put(client, "chat-1", "2026-11-05T10:00:00.000Z", "hello").status_code == 200

    # Another device pulls everything, then only what changed.
    everything = client.get("/api/app-chats").json()
    got = {c["id"]: c for c in everything["chats"]}
    assert got["chat-1"]["record"]["items"][0]["text"] == "hello"
    assert got["chat-1"]["device"] == "mac-a"
    assert first["now"] <= everything["now"]

    assert _put(client, "chat-1", "2026-11-05T10:05:00.000Z", "hello again", device="mac-b").status_code == 200
    changed = client.get("/api/app-chats", params={"since": everything["now"]}).json()
    assert [c["record"]["title"] for c in changed["chats"] if c["id"] == "chat-1"] == ["hello again"]
    assert client.get("/api/app-chats/chat-1").json()["device"] == "mac-b"


def test_older_copy_is_refused_with_the_newer_one():
    client = _client()
    assert _put(client, "chat-2", "2026-11-05T11:00:00.000Z", "newer").status_code == 200
    stale = _put(client, "chat-2", "2026-11-05T10:59:00.000Z", "older")
    assert stale.status_code == 409
    assert stale.json()["detail"]["chat"]["record"]["title"] == "newer"
    assert client.get("/api/app-chats/chat-2").json()["record"]["title"] == "newer"


def test_delete_leaves_a_tombstone_every_device_sees():
    client = _client()
    assert _put(client, "chat-3", "2026-11-05T12:00:00.000Z", "bye").status_code == 200
    before = client.get("/api/app-chats").json()["now"]
    assert client.delete("/api/app-chats/chat-3", params={"device": "mac-a"}).json()["deleted"] is True
    changed = {c["id"]: c for c in client.get("/api/app-chats", params={"since": before}).json()["chats"]}
    assert changed["chat-3"]["deleted"] is True and changed["chat-3"]["record"] is None
    live = {c["id"] for c in client.get("/api/app-chats", params={"include_deleted": False}).json()["chats"]}
    assert "chat-3" not in live
    # A copy older than the delete stays deleted; one edited after it brings the chat back.
    assert _put(client, "chat-3", "2026-11-05T12:30:00.000Z", "stale").status_code == 409
    assert _put(client, "chat-3", "2099-01-01T00:00:00.000Z", "back").status_code == 200
    assert client.get("/api/app-chats/chat-3").json()["deleted"] is False


def test_chat_rules_default_to_never_asking_and_the_library_skills():
    client = _client()
    rules = client.get("/api/chat-rules").json()
    assert rules["never_ask"] is True and rules["default_mode"] == "auto"
    assert "wolfhowl" not in rules["skills"] and "wolfhowl" in rules["library"]
    assert set(rules["skills"]) == set(rules["library"]) - {"wolfhowl", "wolfeat"}

    saved = client.put("/api/chat-rules", json={
        "never_ask": False, "default_mode": "edits", "rules": "Reply in plain English.",
        "skills": [rules["library"][0], "no-such-skill"],
    }).json()
    assert saved["never_ask"] is False and saved["default_mode"] == "edits"
    assert saved["rules"] == "Reply in plain English."
    assert saved["skills"] == [rules["library"][0]]  # skills not in the library drop out
    assert client.get("/api/chat-rules").json()["rules"] == "Reply in plain English."
    assert client.put("/api/chat-rules", json={"default_mode": "yolo"}).status_code == 422


def test_bad_since_and_missing_chat():
    client = _client()
    assert client.get("/api/app-chats", params={"since": "yesterday"}).status_code == 400
    assert client.get("/api/app-chats/nope").status_code == 404
