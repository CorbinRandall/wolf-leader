"""Tests for the audit remediation fixes (A1, B1, D2, D6, kinds filter)."""
from __future__ import annotations

import asyncio
import json

import pytest

from ide_storage.db import db_conn


def _make_project(metadata: dict | None = None, *, name="Proj", slug="proj") -> int:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO projects (name, path, slug, status, created_at, updated_at, metadata)
            VALUES (?, ?, ?, 'active', ?, ?, ?)
            """,
            (name, "/tmp/p", slug, "now", "now", json.dumps(metadata) if metadata else None),
        )
        conn.commit()
        return int(cur.lastrowid)


def _make_chat(*, title, content, status="active", project_id=None) -> int:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO chats (title, content, status, project_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (title, content, status, project_id, "now", "now"),
        )
        conn.commit()
        return int(cur.lastrowid)


def _make_memory(*, project_id, typ="note", content, descriptor=None) -> int:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO memories (project_id, type, content, status, created_at, updated_at, semantic_descriptor)
            VALUES (?, ?, ?, 'active', ?, ?, ?)
            """,
            (project_id, typ, content, "now", "now", descriptor),
        )
        conn.commit()
        return int(cur.lastrowid)


# --- A1: synthesize_descriptor -------------------------------------------------

def test_synthesize_descriptor_composes_fields():
    from ide_storage.embed_index import synthesize_descriptor

    d = synthesize_descriptor(
        kind="memory",
        type="decision",
        content="Use WAL mode for SQLite to avoid writer/reader contention.",
        project_name="Wolf Leader",
    )
    assert "Wolf Leader" in d
    assert "decision:" in d
    assert "Use WAL mode" in d


def test_synthesize_descriptor_truncates_long_content():
    from ide_storage.embed_index import synthesize_descriptor

    d = synthesize_descriptor(kind="memory", content="x" * 1000)
    # ~200 char snippet, no prefix when no project/type
    assert 0 < len(d) <= 220


def test_synthesize_descriptor_handles_missing_fields():
    from ide_storage.embed_index import synthesize_descriptor

    assert synthesize_descriptor(kind="project", content="") == ""


# --- A2/A5: insert_memory synthesizes a fallback when embeddings on -------------

def test_insert_memory_synthesizes_descriptor_when_enabled(monkeypatch):
    monkeypatch.setenv("IDE_STORAGE_EMBEDDINGS_ENABLED", "1")
    # Keep the embedding model out of the loop entirely.
    import ide_storage.embed_index as ei

    monkeypatch.setattr(ei, "embeddings_available", lambda: False)

    pid = _make_project(name="Wolf Leader", slug="wolf-leader")
    from ide_storage.memory_ops import insert_memory

    res = insert_memory(pid, "decision", "Switch to hybrid search with RRF fusion", auto_extracted=True)
    assert res["descriptor_source"] == "synthesized"

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT semantic_descriptor FROM memories WHERE id = ?", (res["id"],))
        descriptor = cur.fetchone()["semantic_descriptor"]
    assert descriptor and "hybrid search" in descriptor


def test_insert_memory_keeps_agent_descriptor(monkeypatch):
    monkeypatch.setenv("IDE_STORAGE_EMBEDDINGS_ENABLED", "1")
    import ide_storage.embed_index as ei

    monkeypatch.setattr(ei, "embeddings_available", lambda: False)
    pid = _make_project()
    from ide_storage.memory_ops import insert_memory

    res = insert_memory(pid, "note", "raw fact here for memory", semantic_descriptor="agent words")
    assert res["descriptor_source"] == "agent"
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT semantic_descriptor FROM memories WHERE id = ?", (res["id"],))
        assert cur.fetchone()["semantic_descriptor"] == "agent words"


def test_insert_memory_no_synthesis_when_disabled():
    pid = _make_project()
    from ide_storage.memory_ops import insert_memory

    res = insert_memory(pid, "note", "another raw fact for storage")
    assert res["descriptor_source"] == "none"
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT semantic_descriptor FROM memories WHERE id = ?", (res["id"],))
        assert cur.fetchone()["semantic_descriptor"] is None


# --- B1: metadata merge on PUT /api/projects/{id} ------------------------------

def test_update_project_merges_metadata():
    from ide_storage import main

    pid = _make_project({"semantic_descriptor": "keep me", "other": 1})
    asyncio.run(main.update_project(pid, main.ProjectUpdate(metadata={"new_key": "v"})))

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT metadata FROM projects WHERE id = ?", (pid,))
        md = json.loads(cur.fetchone()["metadata"])
    assert md["semantic_descriptor"] == "keep me"  # survived partial update
    assert md["other"] == 1
    assert md["new_key"] == "v"


def test_update_project_metadata_can_override_key():
    from ide_storage import main

    pid = _make_project({"semantic_descriptor": "old"})
    asyncio.run(
        main.update_project(pid, main.ProjectUpdate(metadata={"semantic_descriptor": "new"}))
    )
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT metadata FROM projects WHERE id = ?", (pid,))
        md = json.loads(cur.fetchone()["metadata"])
    assert md["semantic_descriptor"] == "new"


# --- D2: archived chats excluded from vector hydration -------------------------

def test_hydrate_knn_rows_excludes_archived_chats():
    from ide_storage.embed_index import _hydrate_knn_rows

    active_id = _make_chat(title="active chat", content="hello", status="active")
    arch_id = _make_chat(title="archived chat", content="bye", status="archived")
    rows = [
        {"kind": "chat", "ref_id": active_id, "distance": 0.1},
        {"kind": "chat", "ref_id": arch_id, "distance": 0.1},
    ]

    default = {r["id"] for r in _hydrate_knn_rows(rows)}
    assert active_id in default
    assert arch_id not in default  # archived excluded by default

    with_arch = {r["id"] for r in _hydrate_knn_rows(rows, include_archived=True)}
    assert arch_id in with_arch  # threaded flag includes it


# --- D6 + kinds filter: keyword search --------------------------------------

def test_keyword_search_matches_semantic_descriptor():
    from ide_storage.search_ops import keyword_search

    pid = _make_project()
    _make_memory(
        project_id=pid,
        content="opaque raw content",
        descriptor="this explains the zebra concept clearly",
    )
    hits = keyword_search("zebra", kinds=frozenset({"memory"}))
    assert any(h["kind"] == "memory" for h in hits)


def test_keyword_search_kinds_filter():
    from ide_storage.search_ops import keyword_search

    pid = _make_project(name="UniqueProjectToken", slug="uniqueprojecttoken")
    _make_memory(project_id=pid, content="UniqueProjectToken appears in memory too")

    only_mem = keyword_search("UniqueProjectToken", kinds=frozenset({"memory"}))
    assert only_mem and all(h["kind"] == "memory" for h in only_mem)

    only_proj = keyword_search("UniqueProjectToken", kinds=frozenset({"project"}))
    assert only_proj and all(h["kind"] == "project" for h in only_proj)


def test_parse_kinds():
    from ide_storage.search_ops import _parse_kinds

    assert _parse_kinds(None) is None
    assert _parse_kinds("") is None
    assert _parse_kinds("memory,project") == frozenset({"memory", "project"})
    assert _parse_kinds("bogus") is None  # invalid filtered out -> None (all kinds)
    assert _parse_kinds("memory,bogus") == frozenset({"memory"})


# --- D3: embed_texts alignment contract ----------------------------------------

def test_embed_texts_returns_none_when_disabled(monkeypatch):
    monkeypatch.delenv("IDE_STORAGE_EMBEDDINGS_ENABLED", raising=False)
    from ide_storage.embeddings import embed_texts

    assert embed_texts(["a", "b"]) is None
