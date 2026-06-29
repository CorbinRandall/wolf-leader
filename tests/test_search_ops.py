"""Tests for hybrid search helpers."""
from ide_storage.search_ops import hybrid_search, reciprocal_rank_fusion


def test_reciprocal_rank_fusion_boosts_overlap():
    keyword = [{"kind": "memory", "id": 1, "title": "a"}]
    vector = [
        {"kind": "memory", "id": 1, "title": "a"},
        {"kind": "project", "id": 2, "title": "b"},
    ]
    merged = reciprocal_rank_fusion([keyword, vector])
    assert merged[0]["kind"] == "memory"
    assert merged[0]["id"] == 1
    assert merged[0]["rrf_score"] > merged[1]["rrf_score"]


def test_hybrid_search_keyword_only_when_embeddings_disabled(monkeypatch):
    monkeypatch.delenv("IDE_STORAGE_EMBEDDINGS_ENABLED", raising=False)
    result = hybrid_search("nonexistent-query-xyz", limit=5)
    assert result["mode"] == "keyword"
    assert result["count"] == 0
