#!/usr/bin/env python3
"""One-time CPU backfill of embedding vectors for existing hub data."""
from __future__ import annotations

import argparse
import json
import time
from datetime import datetime

from ide_storage.db import db_conn
from ide_storage.embed_index import (
    memory_embed_text,
    project_embed_text,
    text_hash,
    _upsert_embedding,
    _existing_hashes,
)
from ide_storage.embeddings import (
    embed_texts,
    embed_model_name,
    embeddings_status,
    embeddings_available,
)

DEFAULT_BATCH = 20


def backfill_kind(kind: str, rows: list, existing_hashes: dict, get_text_fn) -> dict:
    pending = []
    for row in rows:
        text = get_text_fn(row)
        if not text:
            continue
        th = text_hash(text)
        if existing_hashes.get(int(row["id"])) == th:
            continue
        pending.append((int(row["id"]), text, th))
    return {"kind": kind, "total": len(rows), "pending": len(pending), "items": pending}


def run_backfill(project_id=None, batch_size=DEFAULT_BATCH) -> dict:
    if not embeddings_available():
        return {"ok": False, "error": "Embeddings unavailable or disabled"}

    now = datetime.utcnow().isoformat()
    stats = {"memory": 0, "project": 0, "skipped": 0, "errors": 0}

    with db_conn() as conn:
        cur = conn.cursor()

        # -- memories — JOIN projects so embed text includes project name prefix --
        q = """
            SELECT m.id, m.type, m.content, m.semantic_descriptor,
                   p.name AS project_name, p.slug AS project_slug
            FROM memories m
            LEFT JOIN projects p ON p.id = m.project_id
            WHERE COALESCE(m.status, 'active') = 'active'
        """
        params = []
        if project_id is not None:
            q += " AND m.project_id=?"
            params.append(project_id)
        cur.execute(q, params)
        mem_rows = [dict(r) for r in cur.fetchall()]
        mem_hashes = _existing_hashes(cur, "memory")

        # -- projects --
        pq = "SELECT id, name, slug, description, metadata FROM projects WHERE 1=1"
        pparams = []
        if project_id is not None:
            pq += " AND id=?"
            pparams.append(project_id)
        cur.execute(pq, pparams)
        proj_rows = [dict(r) for r in cur.fetchall()]
        proj_hashes = _existing_hashes(cur, "project")

    mem_work = backfill_kind("memory", mem_rows, mem_hashes, memory_embed_text)
    proj_work = backfill_kind("project", proj_rows, proj_hashes, project_embed_text)

    all_work = [("memory", item) for item in mem_work["items"]] + \
               [("project", item) for item in proj_work["items"]]

    stats["skipped"] = (mem_work["total"] - mem_work["pending"]) + \
                       (proj_work["total"] - proj_work["pending"])

    print(f"To embed: {mem_work['pending']} memories, {proj_work['pending']} projects "
          f"({stats['skipped']} already up-to-date)", flush=True)

    for batch_start in range(0, len(all_work), batch_size):
        batch = all_work[batch_start:batch_start + batch_size]
        texts = [item[1] for _, item in batch]
        t0 = time.time()
        vectors = embed_texts(texts)
        elapsed = round(time.time() - t0, 1)
        if vectors is None:
            stats["errors"] += len(batch)
            print(f"  batch {batch_start}-{batch_start+len(batch)}: embedding failed", flush=True)
            continue

        with db_conn() as conn:
            cur = conn.cursor()
            for (kind, (ref_id, embed_text, _)), vector in zip(batch, vectors):
                _upsert_embedding(cur, kind=kind, ref_id=ref_id,
                                  embed_text=embed_text, vector=vector, now=now)
                stats[kind] += 1
            conn.commit()

        done = batch_start + len(batch)
        print(f"  batch {done}/{len(all_work)} embedded in {elapsed}s", flush=True)

    return {"ok": True, "stats": stats, "model": embed_model_name()}


def main() -> None:
    parser = argparse.ArgumentParser(description="Backfill Wolf Leader embedding index")
    parser.add_argument("--project-id", type=int, default=None)
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH)
    args = parser.parse_args()

    status = embeddings_status()
    if not status.get("enabled"):
        raise SystemExit("Set IDE_STORAGE_EMBEDDINGS_ENABLED=1 before running backfill.")
    if not status.get("available"):
        raise SystemExit(f"Embeddings unavailable: {status.get('error')}")

    print(f"Model: {status['model']}", flush=True)
    result = run_backfill(project_id=args.project_id, batch_size=args.batch_size)
    print(json.dumps(result, indent=2))
    if not result.get("ok"):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
