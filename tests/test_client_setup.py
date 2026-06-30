"""Tests for universal client setup API."""
from ide_storage.client_setup import (
    LEGACY_PROFILE_IDS,
    build_agent_prompt,
    client_setup_payload,
)


def test_universal_payload_has_no_niche_labels():
    payload = client_setup_payload()
    prompt = payload["agent_prompt"].lower()
    assert payload["id"] == "universal"
    assert "profiles" not in payload
    assert "unraid" not in prompt
    assert "corbox" not in prompt
    assert "cursor-unraid" not in prompt


def test_agent_prompt_covers_mcp_and_cursor():
    prompt = build_agent_prompt()
    assert "wolf-leader" in prompt
    assert "6972" in prompt or "mcp" in prompt.lower()
    assert "cursor" in prompt.lower()
    assert "claude" in prompt.lower()
    assert "WORKSPACE" in prompt


def test_legacy_profiles_still_resolve():
    for legacy_id in LEGACY_PROFILE_IDS:
        payload = client_setup_payload(legacy_profile=legacy_id)
        assert payload["legacy_profile"] == legacy_id
        assert payload["id"] == "universal"
        assert "deprecated" in payload
