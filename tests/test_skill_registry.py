from __future__ import annotations

import base64
import io
import zipfile

import pytest

from ide_storage.skill_registry import (
    bundle_archive,
    get_skill,
    import_skill,
    import_skill_files,
    list_skills,
    publish_prompt,
    skill_archive,
    seed_builtin_skills,
)


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
    assert get_skill("demo-skill")["description"] == "Demonstrate a portable workflow."
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


def test_install_prompt_documents_network_fallback():
    from ide_storage.skill_registry import install_prompt

    prompt = install_prompt("http://wolf-leader.local:6971")
    assert "If http://wolf-leader.local:6971 is unreachable" in prompt
    assert "configured for this device" in prompt


def test_builtin_wolf_skills_are_seeded(skills_root):
    seed_builtin_skills()
    names = {skill["id"] for skill in list_skills()}
    assert {"wolfhowl", "wolfeat"} <= names
    assert (skills_root / "wolfhowl" / "scripts" / "wolfhowl.sh").is_file()


def _b64(text: str) -> str:
    return base64.b64encode(text.encode()).decode("ascii")


def test_import_names_the_skill_from_its_manifest_folder_or_file(skills_root):
    manifest = "---\nname: Fan Curve Tuner\ndescription: Tune fans.\n---\n# Fans\n"

    # A ZIP of a folder (what Finder and Explorer produce), with no name supplied.
    zipped = import_skill(None, _archive({
        "whatever-folder/SKILL.md": manifest,
        "whatever-folder/scripts/run.sh": "echo hi\n",
        "__MACOSX/whatever-folder/._SKILL.md": "junk",
    }))
    assert zipped["id"] == "fan-curve-tuner"
    assert sorted(zipped["files"]) == ["SKILL.md", "scripts/run.sh"]

    # No manifest name: fall back to the folder, then to the uploaded file name.
    assert import_skill(None, _archive({"My Folder/SKILL.md": "# x\n"}))["id"] == "my-folder"
    assert import_skill(None, _archive({"SKILL.md": "# x\n"}), filename="Quick Notes.zip")["id"] == "quick-notes"
    with pytest.raises(ValueError, match="Skill name"):
        import_skill(None, _archive({"SKILL.md": "# x\n"}))


def test_import_loose_files_from_a_dropped_folder_or_single_skill_md(skills_root):
    manifest = "---\nname: dropped\n---\n# Dropped\n"

    folder = import_skill_files(None, [
        {"path": "dropped/SKILL.md", "content_base64": _b64(manifest)},
        {"path": "dropped/scripts/go.py", "content_base64": _b64("print(1)\n")},
        {"path": "dropped/.DS_Store", "content_base64": _b64("junk")},
    ])
    assert folder["id"] == "dropped"
    assert sorted(folder["files"]) == ["SKILL.md", "scripts/go.py"]

    with pytest.raises(FileExistsError):
        import_skill_files(None, [{"path": "SKILL.md", "content_base64": _b64(manifest)}])
    single = import_skill_files(None, [{"path": "SKILL.md", "content_base64": _b64(manifest)}], overwrite=True)
    assert single["files"] == ["SKILL.md"]

    # A lone, unnamed markdown file takes its uploaded file name.
    unnamed = import_skill_files(None, [{"path": "SKILL.md", "content_base64": _b64("# Notes\n")}], filename="Fan Notes.md")
    assert unnamed["id"] == "fan-notes"

    with pytest.raises(ValueError, match="SKILL.md"):
        import_skill_files("nope", [{"path": "README.md", "content_base64": _b64("x")}])
    with pytest.raises(ValueError, match="Unsafe"):
        import_skill_files("nope", [{"path": "../SKILL.md", "content_base64": _b64("x")}])
    assert not (skills_root / "nope").exists()


def test_import_endpoint_accepts_zip_or_files_and_reports_conflicts(skills_root):
    from fastapi.testclient import TestClient

    from ide_storage.main import app

    client = TestClient(app)
    manifest = "---\nname: api-skill\n---\n# API\n"

    created = client.post("/api/skills/import", json={"files": [{"path": "SKILL.md", "content_base64": _b64(manifest)}]})
    assert created.status_code == 200
    assert created.json()["skill"]["id"] == "api-skill"

    conflict = client.post("/api/skills/import", json={"archive_base64": _archive({"SKILL.md": manifest})})
    assert conflict.status_code == 409
    replaced = client.post("/api/skills/import", json={"archive_base64": _archive({"SKILL.md": manifest}), "overwrite": True})
    assert replaced.status_code == 200

    assert client.post("/api/skills/import", json={}).status_code == 400
