#!/usr/bin/env python3
"""End-of-chat project save: sync transcript → auto-link project → checkpoint."""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Any

from ide_storage.branding import PRODUCT_NAME
from ide_storage.db import db_file
from ide_storage.import_all_transcripts import CATCH_ALL_PROJECT_ID, TRANSCRIPTS_ROOT
from ide_storage.post_save_pipeline import _sync_session, post_save_pipeline
from ide_storage.hub import resolve_project, save_session
from ide_storage.project_match import (
    best_project_match,
    guess_project_from_transcript,
    transcript_text,
)

STATE_FILE = Path(os.environ.get("IDE_STORAGE_SESSION_FILE", "/root/.cursor/wolf-leader-current-session"))


def find_transcript(
    session_id: str | None = None,
    *,
    root: Path = TRANSCRIPTS_ROOT,
) -> tuple[str, Path] | tuple[None, None]:
    """Resolve session id and transcript path (newest session if omitted)."""
    sid = (session_id or os.environ.get("CURSOR_SESSION_ID") or "").strip()
    if not sid and STATE_FILE.is_file():
        sid = STATE_FILE.read_text(encoding="utf-8").splitlines()[0].strip()

    if sid:
        path = root / sid / f"{sid}.jsonl"
        if path.is_file():
            return sid, path

    candidates: list[tuple[float, str, Path]] = []
    if not root.is_dir():
        return None, None
    for child in root.iterdir():
        if not child.is_dir() or child.name == "subagents":
            continue
        p = child / f"{child.name}.jsonl"
        if p.is_file():
            candidates.append((p.stat().st_mtime, child.name, p))
    if not candidates:
        return None, None
    candidates.sort(reverse=True)
    _, sid, path = candidates[0]
    return sid, path


def link_chat_to_project(
    session_id: str,
    project_id: int,
    *,
    db_path: Path | None = None,
    force: bool = False,
) -> dict[str, Any] | None:
    """Assign project_id to chat for session before distill."""
    conn = sqlite3.connect(db_path or db_file())
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute("SELECT id, project_id, title FROM chats WHERE session_id = ?", (session_id,))
    row = cur.fetchone()
    if not row:
        conn.close()
        return None
    current = row["project_id"]
    if current == project_id:
        conn.close()
        return {"chat_id": row["id"], "unchanged": True, "project_id": project_id}
    if current is not None and not force and current != CATCH_ALL_PROJECT_ID:
        conn.close()
        return {"chat_id": row["id"], "skipped": True, "from": current, "to": project_id}

    now = datetime.utcnow().isoformat()
    cur.execute(
        "UPDATE chats SET project_id = ?, updated_at = ? WHERE id = ?",
        (project_id, now, row["id"]),
    )
    conn.commit()
    conn.close()
    return {
        "chat_id": row["id"],
        "from": current,
        "to": project_id,
        "title": row["title"],
        "forced": force,
    }


def save_from_conversation(
    *,
    title: str,
    messages: list[dict[str, str]],
    content: str | None = None,
    project_slug: str | None = None,
    workspace_path: str | None = None,
    session_id: str | None = None,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Save an in-context agent conversation (Claude, etc.) — no Cursor transcript."""
    import uuid

    report: dict[str, Any] = {"ok": False, "steps": [], "source": "conversation"}
    if not messages:
        report["error"] = "messages array is required when no Cursor transcript exists"
        return report

    text = "\n".join(
        (m.get("content") or "").strip()
        for m in messages
        if (m.get("content") or "").strip()
    )
    workspace = workspace_path or os.environ.get("CURSOR_WORKSPACE") or ""
    match: dict[str, Any] | None = None
    project_id: int | None = None

    if project_slug:
        project = resolve_project(slug=project_slug)
        if not project:
            report["error"] = f"Unknown project slug: {project_slug}"
            return report
        project_id = project["id"]
        match = {
            "matched": True,
            "project_id": project_id,
            "slug": project.get("slug"),
            "name": project.get("name"),
            "confidence": "explicit",
            "reasons": [f"user specified slug {project_slug}"],
        }
    else:
        hit = best_project_match(text, db_path=db_path or db_file(), workspace_path=workspace or None)
        if hit:
            project_id = hit["project_id"]
            match = {
                "matched": True,
                "project_id": project_id,
                "slug": hit.get("slug"),
                "name": hit.get("name"),
                "score": hit["score"],
                "confidence": hit["confidence"],
                "reasons": hit.get("reasons"),
            }

    report["project_match"] = match
    report["message_count"] = len(messages)
    report["text_chars"] = len(text)

    sid = session_id or str(uuid.uuid4())
    report["session_id"] = sid

    saved = save_session(
        title=title.strip() or "Agent conversation",
        content=content or f"Saved {len(messages)} messages from agent conversation",
        session_id=sid,
        workspace_path=workspace or None,
        project_id=project_id,
        messages=messages,
    )
    report["steps"].append({"save_session": saved})

    # Never force a relink here: the project was already chosen above from the
    # FULL message text (explicit slug or best_project_match). Forcing a relink
    # re-runs guess_project_id on just title + first messages, which lets a
    # keyword magnet (e.g. SSH) override the correct project. A None project is
    # still relinked downstream because relink_for_session self-forces when unset.
    pipeline = post_save_pipeline(
        session_id=sid,
        chat_id=saved["id"],
        sync=False,
        force_relink=False,
    )
    report["steps"].append({"pipeline": {k: pipeline.get(k) for k in (
        "ok", "error", "project_linked", "project_slug", "project_name",
        "brief_url", "pickup_prompt", "checkpoint_review", "archived",
    ) if k in pipeline}})
    report.update({k: pipeline[k] for k in pipeline if k != "steps"})
    if pipeline.get("ok"):
        return report
    if saved.get("id"):
        report["ok"] = True
        report["chat_id"] = saved["id"]
        report["chat_url"] = f"{os.environ.get('IDE_STORAGE_PUBLIC_URL', 'http://127.0.0.1:6971').rstrip('/')}/?chat={saved['id']}"
        report["project_linked"] = False
        report["note"] = (
            "Chat saved but not linked to a project — assign in web UI or re-run with slug"
        )
    return report


def save_project(
    session_id: str | None = None,
    *,
    project_slug: str | None = None,
    workspace_path: str | None = None,
    title: str | None = None,
    content: str | None = None,
    messages: list[dict[str, str]] | None = None,
    root: Path = TRANSCRIPTS_ROOT,
    db_path: Path | None = None,
    force_relink: bool = True,
) -> dict[str, Any]:
    """
    Save into Wolf Leader — agent transcript and/or in-context messages.

    1. Locate transcript on disk OR use provided messages
    2. Auto-detect project from full conversation (unless slug provided)
    3. Sync → link project → extract memories → distill → archive
    """
    if messages:
        return save_from_conversation(
            title=title or "Agent conversation",
            messages=messages,
            content=content,
            project_slug=project_slug,
            workspace_path=workspace_path,
            session_id=session_id,
            db_path=db_path,
        )

    report: dict[str, Any] = {"ok": False, "steps": [], "source": "cursor_transcript"}

    sid, transcript = find_transcript(session_id, root=root)
    if not sid or not transcript:
        report["error"] = f"No Cursor transcript found under {root}"
        return report

    report["session_id"] = sid
    report["transcript"] = str(transcript)
    report["message_chars"] = len(transcript_text(transcript))

    workspace = workspace_path or os.environ.get("CURSOR_WORKSPACE") or "/root"
    match: dict[str, Any] | None = None

    if project_slug:
        project = resolve_project(slug=project_slug)
        if not project:
            report["error"] = f"Unknown project slug: {project_slug}"
            return report
        match = {
            "matched": True,
            "project_id": project["id"],
            "slug": project.get("slug"),
            "name": project.get("name"),
            "confidence": "explicit",
            "reasons": [f"user specified slug {project_slug}"],
        }
    else:
        match = guess_project_from_transcript(
            transcript, db_path=db_path or db_file(), workspace_path=workspace
        )

    report["project_match"] = match
    report["steps"].append({"detect_project": match})

    sync_result = _sync_session(sid, root=root)
    report["steps"].append({"sync": sync_result})
    if sync_result.get("action") == "error":
        report["error"] = sync_result.get("error", "sync failed")
        return report

    relink_force = force_relink or (match or {}).get("confidence") in (
        "high",
        "explicit",
        "medium",
    )
    if match and match.get("matched") and match.get("project_id"):
        link = link_chat_to_project(
            sid,
            match["project_id"],
            db_path=db_path or db_file(),
            force=relink_force or bool(project_slug),
        )
        if link:
            report["steps"].append({"link_project": link})

    pipeline = post_save_pipeline(
        sid,
        sync=False,
        root=root,
        force_relink=relink_force and not project_slug,
    )
    report["steps"].append({"pipeline": {k: pipeline.get(k) for k in (
        "ok", "error", "project_linked", "project_slug", "project_name",
        "brief_url", "pickup_prompt", "checkpoint_review", "archived",
    ) if k in pipeline}})
    report.update({k: pipeline[k] for k in pipeline if k != "steps"})
    if "steps" in pipeline:
        report.setdefault("pipeline_detail", pipeline["steps"])
    return report


def format_save_summary(report: dict[str, Any]) -> str:
    """Short human-readable result for chat UI."""
    if not report.get("ok"):
        err = report.get("error") or "Save failed"
        match = report.get("project_match") or {}
        if match and not match.get("matched"):
            return (
                f"Synced transcript but could not auto-detect project ({match.get('reason', 'unknown')}). "
                f"Open the chat in {PRODUCT_NAME} and assign a project, or re-run with --slug <slug>."
            )
        return err

    name = report.get("project_name") or report.get("project_slug") or "project"
    slug = report.get("project_slug") or ""
    lines = [
        f"Saved to **{name}** (`{slug}`).",
        f"Session archived; project brief refreshed.",
    ]
    if report.get("brief_url"):
        lines.append(f"Brief: {report['brief_url']}")
    if report.get("pickup_prompt"):
        lines.append(f"Pickup: {report['pickup_prompt']}")
    match = report.get("project_match") or {}
    if match.get("reasons"):
        lines.append(f"Matched because: {', '.join(match['reasons'][:3])}.")
    review = report.get("checkpoint_review") or {}
    if review.get("honest_summary"):
        lines.append(f"Checkpoint: {review['honest_summary']}")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=f"Save current chat to {PRODUCT_NAME} with auto project detection",
    )
    parser.add_argument("--session-id", help="Cursor session UUID (default: current/newest)")
    parser.add_argument("--slug", help="Force project slug (skip auto-detect)")
    parser.add_argument("--workspace", default=None, help="Workspace path hint for matching")
    parser.add_argument("--root", type=Path, default=TRANSCRIPTS_ROOT)
    parser.add_argument("--summary", action="store_true", help="Print human summary only")
    args = parser.parse_args()

    report = save_project(
        args.session_id,
        project_slug=args.slug,
        workspace_path=args.workspace,
        root=args.root,
    )
    if args.summary:
        print(format_save_summary(report))
    else:
        print(json.dumps(report, indent=2))
    if not report.get("ok"):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
