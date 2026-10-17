"""Conversation search: typo fallback, project/date scope, context, decisions, timelines."""
from ide_storage.db import db_conn


def _project(slug: str) -> int:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO projects (name, path, slug, status, created_at, updated_at)
            VALUES (?, ?, ?, 'active', ?, ?)
            """,
            (slug, f"/tmp/{slug}", slug, "2026-10-01T00:00:00", "2026-10-01T00:00:00"),
        )
        conn.commit()
        return int(cur.lastrowid)


def _chat(project_id: int, title: str, occurred_at: str, messages: list[tuple[str, str]]) -> tuple[int, list[int]]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO chats (title, project_id, status, occurred_at, created_at, updated_at, content)
            VALUES (?, ?, 'active', ?, ?, ?, '')
            """,
            (title, project_id, occurred_at, occurred_at, occurred_at),
        )
        chat_id = int(cur.lastrowid)
        ids = []
        for role, text in messages:
            cur.execute(
                "INSERT INTO messages (chat_id, role, content, created_at) VALUES (?, ?, ?, ?)",
                (chat_id, role, text, occurred_at),
            )
            ids.append(int(cur.lastrowid))
        conn.commit()
        return chat_id, ids


def _memory(project_id: int, content: str, source_chat_id: int | None, at: str) -> int:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO memories (project_id, type, content, status, created_at, updated_at, source_chat_id)
            VALUES (?, 'decision', ?, 'active', ?, ?, ?)
            """,
            (project_id, content, at, at, source_chat_id),
        )
        conn.commit()
        return int(cur.lastrowid)


def test_fuzzy_fallback_finds_typo_with_context_and_date():
    from ide_storage.search_ops import hybrid_search

    pid = _project("babyprox")
    _chat(
        pid,
        "Baby Prox display setup",
        "2026-09-03T10:00:00",
        [
            ("user", "What should happen when the lid closes?"),
            ("assistant", "Set the display to turn off on lid close and keep the server awake."),
            ("user", "Good, do that."),
        ],
    )
    result = hybrid_search("lid clsoe", kinds=frozenset({"message"}))
    assert result["fuzzy"] is True
    hit = result["results"][0]
    assert hit["kind"] == "message"
    assert "lid close" in hit["content"].lower()
    assert hit["when"]
    assert hit["context"], "neighbouring messages should be attached"


def test_decisions_linked_to_chat_are_attached():
    from ide_storage.search_ops import hybrid_search

    pid = _project("linked")
    chat_id, _ = _chat(pid, "Power plan", "2026-09-05T09:00:00", [("user", "Lid should sleep the display")])
    _memory(pid, "Display turns off on lid close", chat_id, "2026-09-05T09:30:00")
    result = hybrid_search("lid sleep display", kinds=frozenset({"message"}))
    hit = next(h for h in result["results"] if h["kind"] == "message")
    assert [d["content"] for d in hit["decisions"]] == ["Display turns off on lid close"]


def test_project_and_date_filters():
    from ide_storage.search_ops import hybrid_search

    a = _project("proj-a")
    b = _project("proj-b")
    _chat(a, "A early", "2026-08-01T10:00:00", [("user", "zebra crossing plan")])
    _chat(a, "A late", "2026-09-20T10:00:00", [("user", "zebra crossing again")])
    _chat(b, "B late", "2026-09-20T11:00:00", [("user", "zebra crossing elsewhere")])

    only_a = hybrid_search("zebra crossing", kinds=frozenset({"message"}), project_id=a)
    assert {h["chat_title"] for h in only_a["results"]} == {"A early", "A late"}

    in_sept = hybrid_search(
        "zebra crossing", kinds=frozenset({"message"}), date_from="2026-09-01", date_to="2026-09-30"
    )
    assert {h["chat_title"] for h in in_sept["results"]} == {"A late", "B late"}

    both = hybrid_search(
        "zebra crossing",
        kinds=frozenset({"message"}),
        project_id=a,
        date_from="2026-09-01",
        date_to="2026-09-30",
    )
    assert [h["chat_title"] for h in both["results"]] == ["A late"]


def test_timeline_is_newest_first_and_covers_chats_memories():
    from ide_storage.conversation_search import project_timeline

    pid = _project("timeline")
    chat_id, _ = _chat(pid, "Early chat", "2026-07-01T10:00:00", [("user", "hello")])
    _memory(pid, "Decided on plan X", chat_id, "2026-07-02T10:00:00")
    items = project_timeline(pid)
    assert [i["kind"] for i in items] == ["memory", "chat"]
    assert all(i["when"] for i in items)


def test_window_sync_is_noop_without_embeddings(monkeypatch):
    from ide_storage.conversation_search import sync_conversation_windows

    monkeypatch.setenv("IDE_STORAGE_EMBEDDINGS_ENABLED", "0")
    assert sync_conversation_windows() == {"status": "embeddings unavailable"}
