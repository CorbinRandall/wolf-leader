"""Tests for project_match scoring."""
from __future__ import annotations

from pathlib import Path

import pytest

from ide_storage import project_match as pm


@pytest.fixture
def sample_rows():
    return [
        {
            "id": 1,
            "slug": "s3-sleep",
            "name": "S3 Sleep",
            "description": "Dynamix s3 sleep plugin for disks",
            "compose_path": None,
            "path": "/root",
        },
        {
            "id": 2,
            "slug": "docker-dashboard",
            "name": "Docker Dashboard",
            "description": "Docker apps website with container links",
            "compose_path": None,
            "path": "/root",
        },
    ]


def test_docker_dashboard_wins_over_incidental_sleep(monkeypatch, sample_rows):
    monkeypatch.setattr(pm, "_slug_rows", lambda _db: sample_rows)
    text = """
    User wants the docker dashboard fixed — container links page on port 8888,
    layout for docker apps website, nginx reverse proxy to the dashboard.
    Someone briefly said sleep once when discussing unrelated disk spin-down.
  """ * 4
    matches = pm.score_project_matches(text, db_path=Path("/dev/null"))
    assert matches
    assert matches[0]["slug"] == "docker-dashboard"
    best = pm.best_project_match(text, db_path=Path("/dev/null"))
    assert best is not None
    assert best["slug"] == "docker-dashboard"


def test_ambiguous_close_scores_returns_no_best(monkeypatch, sample_rows):
    monkeypatch.setattr(pm, "_slug_rows", lambda _db: sample_rows)
    text = "docker dashboard and s3 sleep plugin both need work " * 10
    ranked = pm.score_project_matches(text, db_path=Path("/dev/null"))
    assert len(ranked) >= 2
    best = pm.best_project_match(text, db_path=Path("/dev/null"), min_lead=12)
    assert best is None
