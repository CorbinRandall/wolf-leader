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


def test_push_gives_every_tool_the_master_set(tmp_path, monkeypatch):
    import io
    import zipfile

    m = load(tmp_path)
    m.BACKUPS = tmp_path / "backups"
    for home in (".claude", ".codex", ".cursor"):
        (tmp_path / home).mkdir()
    old = tmp_path / ".cursor" / "skills" / "talk"
    old.mkdir(parents=True)
    (old / "SKILL.md").write_text("old words", encoding="utf-8")
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("skills/talk/SKILL.md", "---\nname: talk\n---\n")
    class Reply:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self): return buffer.getvalue()
    monkeypatch.setattr(m.urllib.request, "urlopen", lambda *a, **k: Reply())

    first = m.push_skills("http://unused")
    assert {(a["tool"], a["skill"]) for a in first["added"]} == {("claude", "talk"), ("codex", "talk")}
    assert first["updated"] == [{"tool": "cursor", "skill": "talk"}]
    assert "name: talk" in (old / "SKILL.md").read_text(encoding="utf-8")
    assert any("old words" in f.read_text(encoding="utf-8") for f in m.BACKUPS.rglob("SKILL.md"))
    again = m.push_skills("http://unused")
    assert (again["added"], again["updated"], again["unchanged"]) == ([], [], 3)


def test_remove_skills_keeps_a_backup(tmp_path):
    m = load(tmp_path)
    m.BACKUPS = tmp_path / "backups"
    skill = tmp_path / ".agents" / "skills" / "old"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("x", encoding="utf-8")
    assert m.remove_skills("codex", ["old", "../etc"])["removed"] == ["old"]
    assert not skill.exists()
    assert list(m.BACKUPS.rglob("SKILL.md"))


def test_reads_claude_and_chatgpt_exports(tmp_path):
    import json
    import zipfile

    m = load(tmp_path)
    claude = [{"uuid": "c1", "name": "Mixing vocals", "created_at": "2026-01-02T10:00:00Z", "chat_messages": [
        {"sender": "human", "text": "How do I mix vocals?", "created_at": "2026-01-02T10:00:00Z"},
        {"sender": "assistant", "text": "", "content": [{"type": "text", "text": "Start with EQ."}]},
    ]}]
    chatgpt = [{"id": "g1", "title": "Trip", "create_time": 1767000000, "current_node": "b2", "mapping": {
        "root": {"message": None, "parent": None},
        "a1": {"message": {"author": {"role": "user"}, "content": {"parts": ["Plan a trip"]}}, "parent": "root"},
        "a2": {"message": {"author": {"role": "assistant"}, "content": {"parts": ["Old answer"]}}, "parent": "a1"},
        "b2": {"message": {"author": {"role": "assistant"}, "content": {"parts": ["Kept answer"]}}, "parent": "a1"},
    }}]
    with zipfile.ZipFile(tmp_path / "claude.zip", "w") as z:
        z.writestr("conversations.json", json.dumps(claude))
    unpacked = tmp_path / "chatgpt-export"
    unpacked.mkdir()
    (unpacked / "conversations.json").write_text(json.dumps(chatgpt), encoding="utf-8")
    (tmp_path / "other.zip").write_bytes(b"not a zip")

    found = m.find_exports([str(tmp_path / "claude.zip"), str(unpacked), str(tmp_path / "other.zip")])
    assert found == [tmp_path / "claude.zip", unpacked]
    sessions = {s["id"]: s for s in m.export_sessions(found)}
    assert sessions["claude.ai-c1"]["title"] == "Mixing vocals"
    assert sessions["chatgpt-g1"]["tool"] == "chatgpt"
    convo = m.read_export(unpacked)[0]["messages"]
    assert [x["content"] for x in convo] == ["Plan a trip", "Kept answer"]  # the edited-away branch is dropped
    assert m.read_export(tmp_path / "claude.zip")[0]["messages"][1]["content"] == "Start with EQ."


def test_ai_answer_is_read_as_profile_items(tmp_path):
    m = load(tmp_path)
    answer = 'Sure!\n[{"kind": "style", "text": "I like short answers."}, {"kind": "mood", "text": "I make music."}, {"text": ""}]'
    assert m._json_items(answer) == [{"kind": "style", "text": "I like short answers."}, {"kind": "about", "text": "I make music."}]
    assert m._json_items("no list here") == []
