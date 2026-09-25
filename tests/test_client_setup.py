"""Tests for universal client setup API."""
import io
import tarfile

from ide_storage.client_setup import (
    LEGACY_PROFILE_IDS,
    build_agent_prompt,
    build_client_bundle,
    client_setup_payload,
)


def test_universal_payload_has_no_niche_labels():
    payload = client_setup_payload()
    prompt = payload["agent_prompt"].lower()
    assert payload["id"] == "universal"
    assert "profiles" not in payload
    assert "unraid" not in prompt
    assert "private-server" not in prompt
    assert "cursor-unraid" not in prompt


def test_agent_prompt_covers_mcp_and_cursor():
    prompt = build_agent_prompt()
    assert "wolf-leader" in prompt
    assert "6972" in prompt or "mcp" in prompt.lower()
    assert "cursor" in prompt.lower()
    assert "claude" in prompt.lower()
    assert "WORKSPACE" in prompt


def test_agent_prompt_explains_current_cursor_workflow():
    prompt = build_agent_prompt()
    assert "model policy: economy, balanced, or maximum quality" in prompt
    assert "checkpoint policy" in prompt
    assert "automatic save hook" in prompt
    assert "wolf-leader-last-save.json" in prompt
    assert "deliberate final checkpoint" in prompt


def test_agent_prompt_explains_codex_save_skill():
    prompt = build_agent_prompt()
    assert "Codex integration" in prompt
    assert "examples/codex/skills/save" in prompt
    assert "$CODEX_HOME/skills/save" in prompt
    assert "MCP `save_session`" in prompt


def test_client_bundle_contains_codex_save_skill():
    with tarfile.open(fileobj=io.BytesIO(build_client_bundle()), mode="r:gz") as archive:
        assert "examples/codex/skills/save/SKILL.md" in archive.getnames()


def test_payload_reports_server_identity(monkeypatch):
    monkeypatch.setenv("IDE_STORAGE_PUBLIC_HOST", "100.64.0.15")
    monkeypatch.setenv("IDE_STORAGE_DEVICE_NAME", "example-server")
    monkeypatch.delenv("IDE_STORAGE_PUBLIC_URL", raising=False)
    monkeypatch.delenv("IDE_STORAGE_MCP_URL", raising=False)
    payload = client_setup_payload()
    assert payload["server"]["device_name"] == "example-server"
    assert payload["hub_api"] == "http://100.64.0.15:6971"


def test_copied_prompt_uses_configured_urls(monkeypatch):
    monkeypatch.setenv("IDE_STORAGE_PUBLIC_URL", "https://hub.example.test")
    monkeypatch.setenv("IDE_STORAGE_MCP_URL", "https://hub.example.test/mcp")
    prompt = client_setup_payload()["agent_prompt"]
    assert "Hub API: https://hub.example.test" in prompt
    assert "MCP: https://hub.example.test/mcp" in prompt
    assert "YOUR_HOST" not in prompt


def test_legacy_profiles_still_resolve():
    for legacy_id in LEGACY_PROFILE_IDS:
        payload = client_setup_payload(legacy_profile=legacy_id)
        assert payload["legacy_profile"] == legacy_id
        assert payload["id"] == "universal"
        assert "deprecated" in payload
