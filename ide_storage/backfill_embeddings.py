#!/usr/bin/env python3
"""One-time CPU backfill of embedding vectors for existing hub data."""
from __future__ import annotations

import argparse
import json

from ide_storage.embed_index import sync_dirty
from ide_storage.embeddings import embeddings_status


def main() -> None:
    parser = argparse.ArgumentParser(description="Backfill Wolf Leader embedding index")
    parser.add_argument(
        "--project-id",
        type=int,
        default=None,
        help="Limit backfill to one project",
    )
    args = parser.parse_args()

    status = embeddings_status()
    if not status.get("enabled"):
        raise SystemExit(
            "Set IDE_STORAGE_EMBEDDINGS_ENABLED=1 before running backfill."
        )
    if not status.get("available"):
        raise SystemExit(f"Embeddings unavailable: {status.get('error')}")

    report = sync_dirty(project_id=args.project_id)
    print(json.dumps({"status": status, "report": report}, indent=2))
    if not report.get("ok"):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
