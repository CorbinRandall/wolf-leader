#!/usr/bin/env python3
"""Infer project slug from a Cursor session transcript."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from ide_storage.db import db_file
from ide_storage.import_all_transcripts import TRANSCRIPTS_ROOT
from ide_storage.project_match import guess_project_from_transcript


def guess_slug_for_session(
    session_id: str,
    *,
    db_path: Path | None = None,
    root: Path = TRANSCRIPTS_ROOT,
    workspace_path: str | None = None,
) -> dict:
    path = root / session_id / f"{session_id}.jsonl"
    return guess_project_from_transcript(
        path, db_path=db_path, workspace_path=workspace_path
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("session_id")
    parser.add_argument("--root", type=Path, default=TRANSCRIPTS_ROOT)
    parser.add_argument("--db", type=Path, default=None)
    args = parser.parse_args()
    print(json.dumps(guess_slug_for_session(args.session_id, db_path=args.db, root=args.root)))


if __name__ == "__main__":
    main()
