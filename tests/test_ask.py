"""Plain questions answered from the journal, without a language model."""
from __future__ import annotations

from datetime import datetime

from ide_storage.ask import ask, find_intent, find_project, parse_when
from ide_storage.db import db_conn

NOW = datetime(2026, 10, 13, 15, 0)


def _project(name: str, slug: str) -> int:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("INSERT INTO projects (name, path, slug, status, created_at, updated_at) VALUES (?, '', ?, 'active', 'now', 'now')",
                    (name, slug))
        conn.commit()
        cur.execute("SELECT id FROM projects WHERE slug = ?", (slug,))
        return int(cur.fetchone()["id"])


def _memory(pid: int, kind: str, content: str, when: str) -> None:
    with db_conn() as conn:
        conn.execute("INSERT INTO memories (project_id, type, content, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                     (pid, kind, content, when, when))
        conn.commit()


def test_reads_the_time_named_in_a_question():
    def label(text):
        window = parse_when(text, NOW)
        return window and (window["label"], f"{window['start']:%m-%d}", f"{window['end']:%m-%d}")

    assert label("what did I learn three days ago") == ("3 days ago (Oct 10)", "10-10", "10-11")
    assert label("anything from yesterday?") == ("yesterday", "10-12", "10-13")
    assert label("what broke in the last 2 weeks") == ("the last 14 days", "09-29", "10-14")
    assert label("around March 3")[0] == "around Mar 3"
    assert label("what did we do in September") == ("September 2026", "09-01", "10-01")
    assert label("how does the fan curve work") is None


def test_reads_the_project_and_what_is_asked_about():
    projects = [{"id": 1, "name": "Wolf Leader", "slug": "ide-storage"}, {"id": 2, "name": "Wolf", "slug": "wolf"},
                {"id": 3, "name": "Homelab Cooling", "slug": "homelab-cooling"}]

    assert find_project("What did I learn for wolf leader three days ago?", projects)["id"] == 1
    assert find_project("anything on homelab-cooling", projects)["id"] == 3
    assert find_project("what did I learn", projects) is None
    assert find_intent("What did I learn")[0] == "what you learned"
    assert find_intent("what broke")[1] == ("problem", "caveat")
    assert find_intent("tell me about it") is None


def test_answers_with_the_matching_memories_only():
    wolf, fans = _project("Wolf Leader", "ide-storage"), _project("Homelab Cooling", "homelab-cooling")
    # Hub local time is Pacific; noon Pacific on Oct 10 is 19:00 UTC.
    _memory(wolf, "decision", "wolfhowl is the only save command.", "2026-10-10T19:00:00")
    _memory(wolf, "problem", "The dev compose file took prod down.", "2026-10-10T20:00:00")
    _memory(wolf, "note", "A passing note.", "2026-10-10T20:30:00")
    _memory(wolf, "decision", "An older decision.", "2026-10-02T19:00:00")
    _memory(fans, "decision", "Use the BMC for fan control.", "2026-10-10T19:00:00")

    answer = ask("What did I learn for Wolf Leader three days ago?", now=NOW)

    assert answer["understood"] == {"project": {"id": wolf, "name": "Wolf Leader"}, "when": "3 days ago (Oct 10)",
                                    "about": "what you learned"}
    assert [(s["title"], [i["text"] for i in s["items"]]) for s in answer["sections"]] == [
        ("Decisions", ["wolfhowl is the only save command."]),
        ("Problems", ["The dev compose file took prod down."]),
    ]
    assert answer["summary"].startswith("Here is what you learned for Wolf Leader from 3 days ago (Oct 10): 1 decisions, 1 problems")

    empty = ask("What did I learn for Homelab Cooling yesterday?", now=NOW)
    assert empty["sections"] == [] and empty["summary"].startswith("Nothing saved for Homelab Cooling from yesterday")

    # No project and no time: no made-up answer, just search results.
    plain = ask("fan control", now=NOW)
    assert plain["summary"] == "" and plain["sections"] == []
