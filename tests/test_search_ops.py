"""Tests for hybrid search helpers."""
from ide_storage.search_ops import hybrid_search, reciprocal_rank_fusion


def test_reciprocal_rank_fusion_boosts_overlap():
    keyword = [{"kind": "memory", "id": 1, "title": "a"}]
    vector = [
        {"kind": "memory", "id": 1, "title": "a"},
        {"kind": "project", "id": 2, "title": "b"},
    ]
    merged = reciprocal_rank_fusion(keyword, vector)
    assert merged[0]["kind"] == "memory"
    assert merged[0]["id"] == 1
    assert merged[0]["rrf_score"] > merged[1]["rrf_score"]


def test_hybrid_search_keyword_only_when_embeddings_disabled(monkeypatch):
    monkeypatch.setenv("IDE_STORAGE_EMBEDDINGS_ENABLED", "0")
    result = hybrid_search("nonexistent-query-xyz", limit=5)
    assert result["mode"] == "keyword"
    assert result["count"] == 0


def test_all_words_clause_needs_every_word_in_any_order():
    from ide_storage.search_ops import _all_words_clause

    clause, params = _all_words_clause("lid display", ["m.content"])
    assert clause == "(m.content LIKE ?) AND (m.content LIKE ?)"
    assert params == ["%lid%", "%display%"]


def test_all_words_clause_single_word_matches_old_behaviour():
    from ide_storage.search_ops import _all_words_clause

    clause, params = _all_words_clause("zebra", ["m.content", "m.semantic_descriptor"])
    assert clause == "(m.content LIKE ? OR m.semantic_descriptor LIKE ?)"
    assert params == ["%zebra%", "%zebra%"]


def test_keyword_search_finds_memory_with_words_out_of_order():
    from ide_storage.db import db_conn
    from ide_storage.search_ops import keyword_search

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO projects (name, path, slug, status, created_at, updated_at)
            VALUES ('Proj', '/tmp/proj', 'proj', 'active', 'now', 'now')
            """
        )
        pid = int(cur.lastrowid)
        cur.execute(
            """
            INSERT INTO memories (project_id, type, content, status, created_at, updated_at)
            VALUES (?, 'note', 'Closing the lid should turn the display off', 'active', 'now', 'now')
            """,
            (pid,),
        )
        conn.commit()

    hits = keyword_search("display lid", kinds=frozenset({"memory"}))
    assert any(h["kind"] == "memory" for h in hits)
    assert not keyword_search("display lidnotthere", kinds=frozenset({"memory"}))
