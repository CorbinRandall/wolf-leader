from __future__ import annotations

import base64
import io
import zipfile

import pytest

from ide_storage.skill_registry import (
    bundle_archive,
    get_skill,
    import_skill,
    list_skills,
    publish_prompt,
    skill_archive,
)
from ide_storage.skill_registry import _parse_manifest
from fastapi.testclient import TestClient
from ide_storage.main import app


@pytest.fixture
def skills_root(tmp_path, monkeypatch):
    root = tmp_path / "skills"
    monkeypatch.setenv("IDE_STORAGE_SKILLS_DIR", str(root))
    return root


def _archive(files: dict[str, str]) -> str:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, content in files.items():
            archive.writestr(name, content)
    return base64.b64encode(buffer.getvalue()).decode("ascii")


def test_import_list_get_and_export_complete_skill(skills_root):
    manifest = """---
name: demo-skill
description: Demonstrate a portable workflow.
---

Follow the demo workflow.
"""
    result = import_skill(
        "demo-skill",
        _archive({"demo-skill/SKILL.md": manifest, "demo-skill/scripts/run.py": "print('ok')\n"}),
    )
    assert result["name"] == "demo-skill"
    assert result["file_count"] == 2
    assert list_skills()[0]["description"] == "Demonstrate a portable workflow."
    assert get_skill("demo-skill")["content"] == manifest

    with zipfile.ZipFile(io.BytesIO(skill_archive("demo-skill"))) as archive:
        assert set(archive.namelist()) == {"demo-skill/SKILL.md", "demo-skill/scripts/run.py"}
    with zipfile.ZipFile(io.BytesIO(bundle_archive())) as archive:
        assert "skills/demo-skill/SKILL.md" in archive.namelist()
        assert "INSTALL.txt" in archive.namelist()


def test_import_requires_overwrite_for_existing_skill(skills_root):
    archive = _archive({"demo/SKILL.md": "---\nname: demo\ndescription: Demo.\n---\n"})
    import_skill("demo", archive)
    with pytest.raises(FileExistsError):
        import_skill("demo", archive)
    updated = import_skill("demo", archive, overwrite=True)
    assert updated["id"] == "demo"


def test_import_rejects_path_traversal(skills_root):
    archive = _archive({"../SKILL.md": "unsafe"})
    with pytest.raises(ValueError, match="Unsafe archive path"):
        import_skill("demo", archive)


def test_publish_prompt_contains_hub_upload_and_verification_urls():
    prompt = publish_prompt("http://wolf-leader.local:6971")
    assert "POST JSON to http://wolf-leader.local:6971/api/skills/import" in prompt
    assert "GET http://wolf-leader.local:6971/api/skills/SKILL_ID" in prompt
    assert '"overwrite":true' in prompt
    assert "Do not upload system skills" in prompt
    assert "If http://wolf-leader.local:6971 is unreachable" in prompt
    assert "Do not substitute a guessed hostname" in prompt
    assert '"access_token":"TOKEN"' in prompt
    assert "IDE_STORAGE_SKILLS_WRITE_TOKEN" in prompt


def test_install_prompt_documents_network_fallback():
    from ide_storage.skill_registry import install_prompt

    prompt = install_prompt("http://wolf-leader.local:6971")
    assert "If http://wolf-leader.local:6971 is unreachable" in prompt
    assert "configured for this device" in prompt


def test_parse_folded_description():
    manifest = """---
name: example
description: >-
  A folded description for a skill.
  It spans multiple YAML lines.
---
"""
    assert _parse_manifest(manifest, "fallback") == (
        "example",
        "A folded description for a skill. It spans multiple YAML lines.",
    )


def test_import_rejects_duplicate_archive_paths(skills_root):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive_file:
        archive_file.writestr("demo/SKILL.md", "---\nname: demo\n---\n")
        archive_file.writestr("demo/SKILL.md", "duplicate")
    archive = base64.b64encode(buffer.getvalue()).decode("ascii")
    with pytest.raises(ValueError):
        import_skill("demo", archive)


def test_import_endpoint_requires_configured_token(skills_root, monkeypatch):
    monkeypatch.setenv("IDE_STORAGE_SKILLS_WRITE_TOKEN", "expected-secret")
    archive = _archive({"demo/SKILL.md": "---\nname: demo\n---\n"})
    with TestClient(app) as client:
        denied = client.post("/api/skills/import", json={"name": "demo", "archive_base64": archive})
        assert denied.status_code == 401
        allowed = client.post(
            "/api/skills/import",
            json={"name": "demo", "archive_base64": archive, "access_token": "expected-secret"},
        )
        assert allowed.status_code == 200
        assert allowed.json()["skill"]["id"] == "demo"


def test_publish_helper_requires_https_when_token_is_set(tmp_path, monkeypatch):
    import importlib.util
    from pathlib import Path

    script = Path(__file__).parents[1] / "scripts" / "sync-skills-to-hub.py"
    spec = importlib.util.spec_from_file_location("sync_skills_to_hub", script)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    skill = tmp_path / "demo"
    skill.mkdir()
    (skill / "SKILL.md").write_text("---\nname: demo\n---\n")
    monkeypatch.setenv("IDE_STORAGE_SKILLS_WRITE_TOKEN", "secret")
    with pytest.raises(RuntimeError, match="HTTPS"):
        module.publish_skill("http://wolf-leader.local:6971", "demo", skill)
