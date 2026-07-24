"""Tests for session activity log / where-we-left-off."""
from __future__ import annotations

from ide_storage.left_off import (
    CHAT_AGENT_SUMMARY_KEY,
    CHAT_HUMAN_SUMMARY_KEY,
    LEGACY_OVERRIDE_KEY,
    LEFT_OFF_KEY,
    build_human_log_summary,
    build_session_log_summary,
    get_saved_left_off,
    humanize_log_summary,
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


def test_human_summary_skips_agent_dense_memories():
    text = build_human_log_summary(
        title="Hub work",
        messages=[
            {"role": "user", "content": "Can we make the project summary more readable?"},
            {
                "role": "assistant",
                "content": "Updated the overview so it explains what the project is for in plain language.",
            },
        ],
        extracted_memories=[
            {
                "type": "active_work",
                "content": "handoff_tier continue — do not redeploy; see agent-brief and SPEC.yaml",
            },
            {
                "type": "decision",
                "content": "Keep agent pickup technical; show a friendlier story on the project page.",
            },
        ],
    )
    assert "plain language" in text.lower() or "friendlier" in text.lower() or "readable" in text.lower()
    assert "handoff_tier" not in text
    assert "SPEC.yaml" not in text


def test_log_entry_prefers_stored_human_summary():
    entry = log_entry_from_chat(
        {
            "id": 9,
            "title": "Long first message about deploy paths",
            "content": "Agent note: handoff_tier orient; LXC 103; bin/deploy-hub --proxmox",
            "metadata": {
                CHAT_HUMAN_SUMMARY_KEY: "Made the phone hub an independent backup of the main dashboard.",
                CHAT_AGENT_SUMMARY_KEY: "Phone hub independent; deploy via bin/deploy-hub.",
            },
            "updated_at": "2026-07-24",
        }
    )
    assert "independent backup" in entry["summary"]
    assert "handoff_tier" not in entry["summary"]
    assert "bin/deploy-hub" in (entry.get("agent_summary") or "")


def test_humanize_strips_synced_placeholder():
    assert humanize_log_summary("Synced 12 messages from Cursor transcript", title="Stop button") == "Stop button"
