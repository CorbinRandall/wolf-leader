#!/usr/bin/env python3
"""Bulk-import Cursor agent-transcript JSONL files into Wolf Leader."""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

from ide_storage.import_transcript import API_URL, clean_user, extract_text, parse_transcript
from ide_storage.db import get_db_path

TRANSCRIPTS_ROOT = Path(
    os.environ.get("CURSOR_TRANSCRIPTS_ROOT", "/root/.cursor/projects/root/agent-transcripts")
)
DB_PATH = Path(get_db_path())

# Catch-all server-admin chats use project 1 (compose root) when present.
CATCH_ALL_PROJECT_ID = 1

PROJECT_RULES: list[tuple[int, re.Pattern[str]]] = [
    (
        CATCH_ALL_PROJECT_ID,
        re.compile(
            r"docker container audit|unraid server|content on this server|/root folder",
            re.I,
        ),
    ),
]

TITLE_MAX = 72
GENERIC_DB_TOKENS = {
    "compose",
    "docker",
    "server",
    "stack",
    "unraid",
    "active",
    "centralized",
    "project",
    "hub",
    "sleep",
    "file",
    "port",
    "config",
    "plugin",
    "manager",
    "storage",
    "cursor",
    "agent",
    "chat",
}


def existing_session_ids(db_path: Path) -> set[str]:
    if not db_path.exists():
        return set()
    conn = sqlite3.connect(db_path)
    try:
        cur = conn.cursor()
        cur.execute("SELECT session_id FROM chats WHERE session_id IS NOT NULL")
        return {row[0] for row in cur.fetchall()}
    finally:
        conn.close()


def first_user_text(path: Path) -> str:
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("role") != "user":
            continue
        text = clean_user(extract_text(entry))
        if text:
            return text
    return ""


def make_title(text: str, session_id: str) -> str:
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return f"Cursor chat {session_id[:8]}"
    if len(text) <= TITLE_MAX:
        return text
    cut = text[:TITLE_MAX].rsplit(" ", 1)[0]
    return (cut or text[:TITLE_MAX]).rstrip(".,;:") + "…"


def _strip_hub_paste(text: str) -> str:
    """Remove pasted Wolf Leader / agent context blocks before keyword matching."""
    for marker in (
        "## Project context",
        "## Distilled brief",
        "### Wolf Leader",
        "### IDE Storage",
        "### Load order for a fresh agent",
    ):
        if marker in text:
            text = text.split(marker, 1)[0]
    return text.strip()


def _explicit_project_id(text: str, db_path: Path | None) -> int | None:
    """Honor **Project:** Name (`slug`) from pasted hub context."""
    m = re.search(r"\*\*Project:\*\*[^`\n]*`([a-z0-9][a-z0-9-]*)`", text, re.I)
    if not m:
        m = re.search(r"\*\*Project ID:\*\*\s*(\d+)", text, re.I)
        if m:
            return int(m.group(1))
        return None
    slug = m.group(1).lower()
    if not db_path or not db_path.exists():
        return None
    conn = sqlite3.connect(db_path)
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT id FROM projects WHERE slug = ? AND COALESCE(status, 'active') != 'archived'",
            (slug,),
        )
        row = cur.fetchone()
        return row[0] if row else None
    finally:
        conn.close()


def load_db_project_rules(db_path: Path) -> list[tuple[int, re.Pattern[str]]]:
    """Build match rules from project slug, name, and description in the hub DB."""
    if not db_path.exists():
        return []
    rules: list[tuple[int, re.Pattern[str]]] = []
    known = {project_id for project_id, _ in PROJECT_RULES}
    conn = sqlite3.connect(db_path)
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, name, slug, description FROM projects WHERE COALESCE(status, 'active') != 'archived'"
        )
        for pid, name, slug, description in cur.fetchall():
            if pid in known:
                continue
            tokens: list[str] = []
            if slug:
                tokens.extend(part for part in re.split(r"[-_]+", slug) if len(part) >= 4)
            if name:
                tokens.extend(part for part in re.split(r"\W+", name) if len(part) > 2)
            if description:
                tokens.extend(part for part in re.split(r"\W+", description) if len(part) > 3)
            unique = sorted({token.lower() for token in tokens if token.lower() not in GENERIC_DB_TOKENS})
            if not unique:
                continue
            pattern = "|".join(re.escape(token) for token in unique)
            rules.append((pid, re.compile(pattern, re.I)))
    finally:
        conn.close()
    return rules


def guess_project_id(text: str, db_path: Path | None = None) -> int | None:
    """Pick one project from transcript text using scored full-text matching."""
    explicit = _explicit_project_id(text, db_path)
    if explicit is not None:
        return explicit

    text = _strip_hub_paste(text)
    path = db_path if db_path is not None else DB_PATH

    from ide_storage.project_match import best_project_match

    hit = best_project_match(text, db_path=path)
    return int(hit["project_id"]) if hit else None


def api_request(method: str, url: str, payload: dict | None = None) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())


def import_transcript(
    path: Path,
    *,
    api_url: str,
    skip_ids: set[str],
    db_path: Path = DB_PATH,
    dry_run: bool = False,
    device_name: str = "unraid-server",
    workspace_path: str = "/root",
) -> dict:
    session_id = path.parent.name if path.parent.name != "subagents" else path.stem
    if session_id in skip_ids:
        return {"session_id": session_id, "action": "skipped", "reason": "already in db"}

    messages = parse_transcript(path)
    if not messages:
        return {"session_id": session_id, "action": "skipped", "reason": "no messages"}

    first_text = first_user_text(path)
    title = make_title(first_text, session_id)
    project_id = guess_project_id(first_text, db_path=db_path)
    summary = f"Imported {len(messages)} messages from Cursor transcript"

    result = {
        "session_id": session_id,
        "title": title,
        "project_id": project_id,
        "messages": len(messages),
        "path": str(path),
    }

    if dry_run:
        result["action"] = "dry_run"
        return result

    payload = {
        "title": title,
        "workspace_path": workspace_path,
        "device_name": device_name,
        "session_id": session_id,
        "content": summary,
        "messages": messages,
    }
    created = api_request("POST", api_url, payload)
    chat_id = created["id"]
    result["chat_id"] = chat_id
    result["action"] = created.get("action", "created")

    if project_id is not None:
        api_request("PUT", f"{api_url}/{chat_id}", {"project_id": project_id})
        result["project_linked"] = True

    skip_ids.add(session_id)
    return result


def discover_transcripts(root: Path, session_id: str | None = None) -> list[Path]:
    files: list[Path] = []
    for session_dir in sorted(root.iterdir()):
        if not session_dir.is_dir():
            continue
        if session_id and session_dir.name != session_id:
            continue
        main = session_dir / f"{session_dir.name}.jsonl"
        if main.is_file():
            files.append(main)
    return files


def sync_transcript(
    path: Path,
    *,
    db_path: Path,
    dry_run: bool = False,
) -> dict:
    """Replace messages for an existing chat from its transcript file."""
    session_id = path.parent.name
    messages = parse_transcript(path)
    if not messages:
        return {"session_id": session_id, "action": "skipped", "reason": "no messages"}

    first_text = first_user_text(path)
    title = make_title(first_text, session_id)
    guessed_project = guess_project_id(first_text, db_path=db_path)
    summary = f"Synced {len(messages)} messages from Cursor transcript"
    result = {
        "session_id": session_id,
        "title": title,
        "messages": len(messages),
        "path": str(path),
    }

    if dry_run:
        result["action"] = "sync_dry_run"
        return result

    now = datetime.utcnow().isoformat()
    conn = sqlite3.connect(db_path)
    try:
        cur = conn.cursor()
        cur.execute("SELECT id, project_id FROM chats WHERE session_id = ?", (session_id,))
        row = cur.fetchone()
        if not row:
            conn.close()
            return {"session_id": session_id, "action": "missing", "reason": "not in db"}

        chat_id, current_project = row
        project_id = guessed_project or current_project
        if (
            guessed_project is not None
            and current_project == CATCH_ALL_PROJECT_ID
            and guessed_project != CATCH_ALL_PROJECT_ID
        ):
            project_id = guessed_project
        cur.execute("DELETE FROM messages WHERE chat_id = ?", (chat_id,))
        for msg in messages:
            cur.execute(
                """
                INSERT INTO messages (chat_id, role, content, created_at, metadata)
                VALUES (?, ?, ?, ?, NULL)
                """,
                (chat_id, msg["role"], msg["content"], now),
            )
        cur.execute(
            """
            UPDATE chats
            SET content = ?, project_id = ?, updated_at = ?
            WHERE id = ?
            """,
            (summary, project_id, now, chat_id),
        )
        conn.commit()
    finally:
        conn.close()

    result.update(
        {
            "action": "synced",
            "chat_id": chat_id,
            "project_id": project_id,
        }
    )
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description="Bulk import Cursor transcripts")
    parser.add_argument("--root", type=Path, default=TRANSCRIPTS_ROOT)
    parser.add_argument("--api", default=API_URL)
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--sync", action="store_true", help="Re-sync full messages for chats already in DB")
    parser.add_argument("--session-id", help="Only import/sync this session UUID")
    parser.add_argument("--device-name", default="unraid-server")
    parser.add_argument("--workspace", default="/root")
    parser.add_argument("--skip-pipeline", action="store_true", help="Do not run relink/distill after import")
    args = parser.parse_args()

    skip_ids = existing_session_ids(args.db)
    results = []
    for path in discover_transcripts(args.root, session_id=args.session_id):
        try:
            session_id = path.parent.name
            if session_id in skip_ids and args.sync:
                result = sync_transcript(path, db_path=args.db, dry_run=args.dry_run)
                results.append(result)
                if not args.dry_run and not args.skip_pipeline and result.get("action") == "synced":
                    from ide_storage.post_save_pipeline import post_save_pipeline

                    results.append({"pipeline": post_save_pipeline(session_id, sync=False)})
                continue
            if session_id in skip_ids and not args.sync:
                results.append(
                    {
                        "session_id": session_id,
                        "action": "skipped",
                        "reason": "already in db (use --sync to refresh)",
                    }
                )
                continue
            result = import_transcript(
                path,
                api_url=args.api,
                skip_ids=skip_ids,
                db_path=args.db,
                dry_run=args.dry_run,
                device_name=args.device_name,
                workspace_path=args.workspace,
            )
            results.append(result)
            if (
                not args.dry_run
                and not args.skip_pipeline
                and result.get("action") in {"created", "updated"}
            ):
                from ide_storage.post_save_pipeline import post_save_pipeline

                results.append({"pipeline": post_save_pipeline(session_id, sync=False)})
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")
            results.append(
                {
                    "session_id": path.parent.name,
                    "action": "error",
                    "error": f"HTTP {exc.code}: {body[:300]}",
                    "path": str(path),
                }
            )
        except Exception as exc:  # noqa: BLE001
            results.append(
                {
                    "session_id": path.parent.name,
                    "action": "error",
                    "error": str(exc),
                    "path": str(path),
                }
            )

    created = sum(1 for r in results if r.get("action") in {"created", "updated"})
    synced = sum(1 for r in results if r.get("action") == "synced")
    skipped = sum(1 for r in results if r.get("action") == "skipped")
    errors = [r for r in results if r.get("action") == "error"]
    print(
        json.dumps(
            {"created": created, "synced": synced, "skipped": skipped, "errors": len(errors), "results": results},
            indent=2,
        )
    )
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
