"""Tests for session activity log / where-we-left-off."""
from __future__ import annotations

from ide_storage.left_off import (
    LEGACY_OVERRIDE_KEY,
    LEFT_OFF_KEY,
    build_session_log_summary,
    get_saved_left_off,
    left_off_payload,
    log_entry_from_chat,
    metadata_with_left_off,
    resolve_pickup,
)


def test_build_summary_from_extracted_memories():
    text = build_session_log_summary(
        title="Stop button work",
        messages=[],
        extracted_memories=[
            {"type": "active_work", "content": "Finish dashboard Stop button UI"},
            {"type": "decision", "content": "Keep pickup driven by /save session logs"},
        ],
    )
    assert "Stop button" in text
    assert "pickup" in text.lower() or "save" in text.lower()
    assert len(text) < 500


def test_build_summary_from_assistant_signal():
    text = build_session_log_summary(
        title="Misc",
        messages=[
            {"role": "user", "content": "ship the feature"},
            {
                "role": "assistant",
                "content": "Shipped the where-we-left-off log book on Proxmox and removed the manual form.",
            },
        ],
    )
    assert "where-we-left-off" in text.lower() or "Shipped" in text


def test_build_summary_falls_back_to_user_ask():
    text = build_session_log_summary(
        title="Chat #12",
        messages=[{"role": "user", "content": "Please wire up Docker health checks for the archive service."}],
    )
    assert "health checks" in text.lower() or "Worked on" in text


def test_log_entry_falls_back_when_generic_content():
    entry = log_entry_from_chat(
        {"id": 5, "title": "Real session title", "content": "Saved 12 messages from agent conversation", "updated_at": "2026-07-14"}
    )
    assert entry["summary"] == "Real session title"


def test_left_off_payload_uses_latest_entry():
    project = {"metadata": {}}
    entries = [
        {"chat_id": 2, "title": "Newest", "summary": "Finished Stop button and verified on LXC.", "updated_at": "2026-07-14"},
        {"chat_id": 1, "title": "Older", "summary": "Older work.", "updated_at": "2026-07-01"},
    ]
    payload = left_off_payload(
        project,
        brief_url="http://hub/api/projects/x/agent-brief",
        log_entries=entries,
        default_pickup="fallback",
    )
    assert payload["latest"]["chat_id"] == 2
    assert "Finished Stop button" in payload["pickup"]
    assert "agent-brief" in payload["pickup"]
    assert len(payload["entries"]) == 2


def test_resolve_pickup_honors_metadata():
    project = {"metadata": {LEFT_OFF_KEY: "Manual leftover note"}}
    pickup, from_saved = resolve_pickup(project, default_pickup="auto", brief_url="http://b")
    assert from_saved is True
    assert "Manual leftover note" in pickup


def test_metadata_clears_legacy_alias():
    project = {"metadata": {LEGACY_OVERRIDE_KEY: "old", "continue_mode": "compose_maintain"}}
    meta = metadata_with_left_off(project, "new spot")
    assert meta[LEFT_OFF_KEY] == "new spot"
    assert meta[LEGACY_OVERRIDE_KEY] == "new spot"
    cleared = metadata_with_left_off({"metadata": meta}, "")
    assert LEFT_OFF_KEY not in cleared
    assert LEGACY_OVERRIDE_KEY not in cleared
    assert get_saved_left_off({"metadata": cleared}) is None
