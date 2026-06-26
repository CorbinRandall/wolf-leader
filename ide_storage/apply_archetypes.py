#!/usr/bin/env python3
"""Apply project archetypes: create Hermes, fix relinks, set metadata, distill specs."""
from __future__ import annotations

import argparse
import json
import sqlite3
from datetime import datetime
from pathlib import Path

from ide_storage.db import get_db_path
from ide_storage.distill_spec import distill_all_specs
from ide_storage.project_archetypes import SLUG_ARCHETYPES, metadata_patch
from ide_storage.relink_chats import relink_chat
from ide_storage.topic_projects import migrate_catch_all_topics

DB_PATH = Path(get_db_path())


def apply_metadata(db_path: Path = DB_PATH) -> int:
    now = datetime.utcnow().isoformat()
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute("SELECT * FROM projects WHERE COALESCE(status, 'active') != 'archived'")
    updated = 0
    for row in cur.fetchall():
        project = dict(row)
        slug = (project.get("slug") or "").lower()
        if slug not in SLUG_ARCHETYPES and not project.get("compose_path"):
            continue
        mode, state = SLUG_ARCHETYPES.get(slug, (None, None))
        if slug in ("nextcloud", "immich", "wolf-leader", "ide-storage"):
            mode, state = "compose_maintain", "deployed"
        elif project.get("compose_path") and not mode:
            mode, state = "compose_deploy", "n/a"
        if not mode:
            continue
        meta = metadata_patch(project, continue_mode=mode, deploy_state=state)
        cur.execute(
            "UPDATE projects SET metadata = ?, updated_at = ? WHERE id = ?",
            (json.dumps(meta), now, project["id"]),
        )
        updated += 1
    conn.commit()
    conn.close()
    return updated


def fix_manual_relinks(db_path: Path = DB_PATH) -> list[dict]:
    from ide_storage.relink_chats import MANUAL_LINKS

    now = datetime.utcnow().isoformat()
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    results = []
    for chat_id in MANUAL_LINKS:
        r = relink_chat(cur, chat_id, db_path=db_path, force=True, now=now)
        if r:
            results.append(r)
    conn.commit()
    conn.close()
    return results


def main() -> None:
    parser = argparse.ArgumentParser(description="Apply Wolf Leader project archetypes")
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--skip-distill", action="store_true")
    args = parser.parse_args()

    topic = migrate_catch_all_topics(args.db, dry_run=False)
    relinks = fix_manual_relinks(args.db)
    meta_n = apply_metadata(args.db)
    specs = [] if args.skip_distill else distill_all_specs()

    print(
        json.dumps(
            {
                "topic_migration": topic,
                "manual_relinks": relinks,
                "metadata_updated": meta_n,
                "specs_distilled": len(specs),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
