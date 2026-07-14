"""Tests for where-we-left-off helpers."""
from __future__ import annotations

from ide_storage.left_off import (
    LEGACY_OVERRIDE_KEY,
    LEFT_OFF_KEY,
    build_auto_snapshot,
    ensure_brief_url,
    get_saved_left_off,
    metadata_with_left_off,
    resolve_pickup,
    suggest_left_off_text,
)


def test_get_saved_prefers_canonical_then_legacy():
    project = {"metadata": {LEFT_OFF_KEY: "canonical spot", LEGACY_OVERRIDE_KEY: "legacy"}}
    assert get_saved_left_off(project) == "canonical spot"
    project2 = {"metadata": f'{{"{LEGACY_OVERRIDE_KEY}": "legacy only"}}'}
    assert get_saved_left_off(project2) == "legacy only"
    assert get_saved_left_off({"metadata": None}) is None


def test_resolve_pickup_uses_saved_and_appends_brief():
    project = {"metadata": {LEFT_OFF_KEY: "Finish Stop button UI"}}
    pickup, from_saved = resolve_pickup(
        project,
        default_pickup="Continue project — maintain only.",
        brief_url="http://example/agent-brief",
    )
    assert from_saved is True
    assert "Finish Stop button UI" in pickup
    assert "Brief: http://example/agent-brief" in pickup


def test_resolve_pickup_falls_back_without_saved():
    pickup, from_saved = resolve_pickup(
        {"metadata": {}},
        default_pickup="auto prompt",
        brief_url="http://example/agent-brief",
    )
    assert from_saved is False
    assert pickup == "auto prompt"


def test_ensure_brief_url_skips_when_present():
    text = "Work items\nBrief: http://already/there"
    assert ensure_brief_url(text, "http://other") == text


def test_build_auto_snapshot_from_session_and_active_work():
    snap = build_auto_snapshot(
        archived_recent_sessions=[{"id": 9, "title": "Stop button WIP", "updated_at": "2026-07-14T12:00:00"}],
        memories=[
            {"type": "active_work", "content": "Finish dashboard Stop button"},
            {"type": "decision", "content": "Use compose_maintain"},
            {"type": "active_work", "content": "CLI live progress"},
        ],
    )
    assert snap["last_activity"]["title"] == "Stop button WIP"
    assert "Finish dashboard Stop button" in snap["open_items"]
    assert "CLI live progress" in snap["open_items"]
    assert "Open items:" in snap["summary"]


def test_metadata_with_left_off_sets_and_clears_both_keys():
    project = {"metadata": {"continue_mode": "compose_maintain", LEGACY_OVERRIDE_KEY: "old"}}
    meta = metadata_with_left_off(project, "New spot", updated_at="2026-07-14T01:02:03")
    assert meta["continue_mode"] == "compose_maintain"
    assert meta[LEFT_OFF_KEY] == "New spot"
    assert meta[LEGACY_OVERRIDE_KEY] == "New spot"
    assert meta["where_we_left_off_at"] == "2026-07-14T01:02:03"

    cleared = metadata_with_left_off({**project, "metadata": meta}, "")
    assert LEFT_OFF_KEY not in cleared
    assert LEGACY_OVERRIDE_KEY not in cleared
    assert "continue_mode" in cleared


def test_suggest_includes_name_and_items():
    text = suggest_left_off_text(
        project={"name": "iMessage Archive", "slug": "imessage-archive"},
        brief_url="http://hub/api/projects/imessage-archive/agent-brief",
        archived_recent_sessions=[{"id": 1, "title": "Dashboard work", "updated_at": "2026-07-14T00:00:00"}],
        memories=[{"type": "active_work", "content": "Stop button"}],
    )
    assert "iMessage Archive" in text
    assert "Stop button" in text
    assert "agent-brief" in text
