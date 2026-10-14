"""The history scanner: which folders count, and how a profile lands in each AI tool's notes."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load(home: Path):
    spec = importlib.util.spec_from_file_location("wolf_import", ROOT / "scripts" / "wolf-import.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.HOME = home
    module.TOOL_HOMES = {"claude": home / ".claude", "codex": home / ".codex", "cursor": home / ".cursor"}
    module.SKILL_DIRS = {"claude": home / ".claude" / "skills", "codex": home / ".agents" / "skills",
                         "cursor": home / ".cursor" / "skills"}
    module.profile_target = lambda tool: {"claude": home / ".claude" / "CLAUDE.md", "codex": home / ".codex" / "AGENTS.md",
                                          "cursor": home / ".cursor" / "rules" / "wolf-leader-profile.mdc"}[tool]
    return module


def test_broad_folders_are_not_projects(tmp_path):
    m = load(tmp_path)
    home = "/" + "Users/example"
    assert m.is_broad(home)
    assert m.is_broad(home + "/Downloads")
    assert m.is_broad("/tmp")
    assert not m.is_broad(home + "/Projects/album")


def test_profile_block_replaces_only_itself(tmp_path):
    m = load(tmp_path)
    notes = tmp_path / ".claude" / "CLAUDE.md"
    notes.parent.mkdir(parents=True)
    notes.write_text("My own rules.\n", encoding="utf-8")
    m.write_profile("claude", "# Corbin\n- likes short answers")
    m.write_profile("claude", "# Corbin\n- likes very short answers")
    text = notes.read_text(encoding="utf-8")
    assert text.startswith("My own rules.")
    assert text.count(m.START) == 1
    assert "very short" in text and "- likes short answers" not in text


def test_skills_copy_without_overwriting(tmp_path):
    m = load(tmp_path)
    source = tmp_path / ".agents" / "skills" / "talk"
    source.mkdir(parents=True)
    (source / "SKILL.md").write_text("---\nname: talk\n---\n", encoding="utf-8")
    kept = tmp_path / ".cursor" / "skills" / "talk"
    kept.mkdir(parents=True)
    (kept / "SKILL.md").write_text("mine", encoding="utf-8")
    (tmp_path / ".claude").mkdir()
    (tmp_path / ".codex").mkdir()
    result = m.send_to_tools("http://unused", "", ["claude", "codex", "cursor"], ["talk"])
    assert result["skills"] == [{"skill": "talk", "tool": "claude"}]
    assert (tmp_path / ".claude" / "skills" / "talk" / "SKILL.md").is_file()
    assert (kept / "SKILL.md").read_text(encoding="utf-8") == "mine"
