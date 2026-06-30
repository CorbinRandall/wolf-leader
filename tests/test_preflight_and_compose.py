"""Tests for honest preflight when deployment is unobservable and compose extraction."""
from __future__ import annotations

from ide_storage.compose_extract import merge_services
from ide_storage.handoff import compute_handoff_tier, pickup_for_tier
from ide_storage.preflight import run_preflight


def test_merge_services_returns_empty_without_compose_on_disk(monkeypatch):
    """Chat prose must not become fabricated docker services."""
    monkeypatch.setattr("ide_storage.compose_extract.os.path.isdir", lambda _p: False)
    monkeypatch.setattr(
        "ide_storage.compose_extract.discover_compose_path",
        lambda *a, **k: None,
    )
    texts = [
        "The container might need more RAM for the image/RAM footprint discussion.",
        "We talked at 23:27 and 16:36 about ports 6971:6971 mapping.",
        "Service recreated on the host yesterday.",
    ]
    assert merge_services("", texts, "ide-storage", project={}) == []


def test_merge_services_prefers_real_compose_file(tmp_path):
    compose_dir = tmp_path / "stack"
    compose_dir.mkdir()
    (compose_dir / "docker-compose.yml").write_text(
        "services:\n  hub:\n    image: wolf-leader:latest\n    ports:\n      - '6971:6971'\n",
        encoding="utf-8",
    )
    services = merge_services(str(compose_dir), ["ignore this prose"], "ide-storage")
    assert len(services) == 1
    assert services[0]["name"] == "hub"
    assert "6971:6971" in services[0]["ports"][0]


def test_compose_preflight_unknown_when_docker_unavailable(monkeypatch):
    monkeypatch.setattr("ide_storage.preflight._docker_available", lambda: False)
    project = {
        "compose_path": "/boot/config/plugins/compose.manager/projects/ide-storage",
        "metadata": '{"continue_mode": "compose_maintain", "deploy_state": "deployed"}',
    }
    pf = run_preflight(project, slug="ide-storage", continue_mode="compose_maintain")
    assert pf["docker_check"] == "unavailable"
    assert pf["observed_deploy_state"] == "unknown"
    assert pf["compose"] == "unknown"
    assert pf["appdata"] == "unknown"
    assert pf.get("appdata_path") is None


def test_compose_maintain_continue_when_unobservable():
    pf = {
        "kind": "compose",
        "compose": "unknown",
        "observed_deploy_state": "unknown",
        "containers_running": False,
        "docker_check": "unavailable",
    }
    assert compute_handoff_tier("compose_maintain", pf) == "continue"


def test_pickup_compose_maintain_unobservable():
    pickup = pickup_for_tier(
        "Wolf Leader",
        "ide-storage",
        handoff_tier="continue",
        continue_mode="compose_maintain",
        brief_url="http://192.168.1.221:6971/api/projects/ide-storage/agent-brief",
        preflight={
            "observed_deploy_state": "unknown",
            "docker_check": "unavailable",
            "compose": "unknown",
        },
    )
    assert "not observable" in pickup
    assert "do NOT redeploy" in pickup
