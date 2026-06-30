#!/usr/bin/env python3
"""Post-save pipeline: sync → relink → distill."""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

from ide_storage.distill_project import distill_project
from ide_storage.distill_spec import distill_spec, read_spec_yaml
from ide_storage.spec_validation import validate_spec
from ide_storage.project_archetypes import get_continue_mode, get_deploy_state, pickup_prompt
from ide_storage.memory_ops import archive_chat, extract_memories_for_project
from ide_storage.markdown_sync import read_agent_brief, regenerate_index
from ide_storage.db import db_file, get_db_path
from ide_storage.relink_chats import relink_for_session

TRANSCRIPTS_ROOT = Path("/root/.cursor/projects/root/agent-transcripts")


def _public_base() -> str:
    return os.environ.get("IDE_STORAGE_PUBLIC_URL", "http://127.0.0.1:6971").rstrip("/")


def _agent_prompt(name: str, slug: str, compose_path: str = "") -> str:
    from ide_storage.context import build_agent_start_prompt

    return build_agent_start_prompt(name, slug, compose_path)


def _get_chat(session_id: str | None = None, chat_id: int | None = None) -> dict | None:
    conn = sqlite3.connect(db_file())
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    if chat_id:
        cur.execute("SELECT * FROM chats WHERE id = ?", (chat_id,))
    elif session_id:
        cur.execute("SELECT * FROM chats WHERE session_id = ?", (session_id,))
    else:
        conn.close()
        return None
    row = cur.fetchone()
    conn.close()
    return dict(row) if row else None


def _get_project(project_id: int) -> dict | None:
    conn = sqlite3.connect(db_file())
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
    row = cur.fetchone()
    conn.close()
    return dict(row) if row else None


def _sync_session(session_id: str, root: Path = TRANSCRIPTS_ROOT) -> dict:
    """Run import_all_transcripts --sync for one session."""
    cmd = [
        sys.executable,
        "-m",
        "ide_storage.import_all_transcripts",
        "--sync",
        "--session-id",
        session_id,
        "--root",
        str(root),
        "--db",
        get_db_path(),
        "--skip-pipeline",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        return {"action": "error", "error": proc.stderr or proc.stdout}
    try:
        data = json.loads(proc.stdout)
        results = data.get("results") or []
        if results:
            return results[0]
        return {"action": "skipped", "session_id": session_id}
    except json.JSONDecodeError:
        return {"action": "synced", "session_id": session_id, "raw": proc.stdout[:500]}


def post_save_pipeline(
    session_id: str | None = None,
    *,
    chat_id: int | None = None,
    sync: bool = True,
    root: Path = TRANSCRIPTS_ROOT,
    force_relink: bool = False,
) -> dict:
    """
    1. sync full transcript (optional)
    2. relink chat to project
    3. distill project brief
    """
    report: dict = {"steps": []}

    if sync and session_id:
        sync_result = _sync_session(session_id, root=root)
        report["steps"].append({"sync": sync_result})
        if sync_result.get("action") == "error":
            report["ok"] = False
            return report

    sid = session_id
    if not sid and chat_id:
        chat = _get_chat(chat_id=chat_id)
        sid = chat.get("session_id") if chat else None

    if sid:
        relink = relink_for_session(sid, force=force_relink)
        if relink:
            report["steps"].append({"relink": relink})

    chat = _get_chat(session_id=sid, chat_id=chat_id)
    if not chat and sid:
        chat = _get_chat(session_id=sid)
    if not chat:
        report["ok"] = False
        report["error"] = "Chat not found after sync"
        return report

    report["chat_id"] = chat["id"]
    report["chat_url"] = f"{_public_base()}/?chat={chat['id']}"
    report["message_count"] = _message_count(chat["id"])

    project_id = chat.get("project_id")
    if not project_id:
        report["ok"] = True
        report["project_linked"] = False
        report["note"] = "Chat not linked to a project; brief not refreshed"
        regenerate_index()
        return report

    project = _get_project(project_id)
    if not project:
        report["ok"] = False
        report["error"] = f"Project {project_id} missing"
        return report

    slug = project.get("slug") or f"project-{project_id}"
    extract = extract_memories_for_project(project_id, chat_id=chat["id"], max_new=5)
    report["steps"].append({"extract_memories": extract})
    # A4: soft, non-breaking observability — bubble up when memories were saved
    # without an agent-provided descriptor and embeddings are on (descriptors
    # were auto-synthesized server-side).
    if extract.get("warnings"):
        report.setdefault("warnings", []).extend(extract["warnings"])
    spec_result = distill_spec(project_id)
    report["steps"].append({"distill_spec": spec_result})
    spec_yaml = read_spec_yaml(slug)
    spec_validation = spec_result.get("spec_validation") or validate_spec(
        spec_yaml, get_continue_mode(project)
    )
    report["steps"].append({"spec_validation": spec_validation})
    if not spec_validation.get("valid"):
        report["spec_warnings"] = spec_validation.get("errors", [])
    distill = distill_project(project_id)
    report["steps"].append({"distill": distill})
    archived = archive_chat(chat["id"])
    report["steps"].append({"archive": archived})
    regenerate_index()

    report["ok"] = True
    report["archived"] = archived.get("archived", False)
    report["project_id"] = project_id
    report["project_name"] = project.get("name")
    report["project_slug"] = slug
    report["project_url"] = f"{_public_base()}/?project={project_id}"
    report["brief_url"] = f"{_public_base()}/api/projects/{slug}/agent-brief"
    report["pickup_prompt"] = spec_result.get("pickup") or pickup_prompt(project, public_base=_public_base())
    report["continue_mode"] = spec_result.get("continue_mode") or get_continue_mode(project)
    report["deploy_state"] = spec_result.get("deploy_state") or get_deploy_state(project)
    report["handoff_tier"] = spec_result.get("handoff_tier")
    report["preflight"] = spec_result.get("preflight")
    report["drill_down"] = spec_result.get("drill_down")
    report["agent_prompt"] = report["pickup_prompt"]
    report["spec_yaml"] = spec_yaml
    report["spec_validation"] = spec_validation
    report["spec_chars"] = spec_result.get("spec_chars")
    report["brief_chars"] = distill.get("brief_chars")
    report["brief_md"] = read_agent_brief(slug)
    report["checkpoint_review"] = {
        "handoff_tier": spec_result.get("handoff_tier"),
        "deploy_state": spec_result.get("deploy_state"),
        "observed": (spec_result.get("preflight") or {}).get("observed_deploy_state"),
        "on_disk": {
            k: (spec_result.get("preflight") or {}).get(k)
            for k in ("compose", "appdata", "containers_running")
        },
        "drill_down_required": (spec_result.get("drill_down") or {}).get("required"),
        "spec_errors": spec_validation.get("errors"),
        "spec_warnings": spec_validation.get("warnings"),
        "honest_summary": _checkpoint_summary(spec_result, spec_validation),
    }

    from ide_storage.embed_index import sync_dirty

    report["embeddings"] = sync_dirty(
        project_id=project_id,
        chat_ids=[chat["id"]],
    )
    return report


def _checkpoint_summary(spec_result: dict, validation: dict) -> str:
    tier = spec_result.get("handoff_tier") or "unknown"
    pf = spec_result.get("preflight") or {}
    parts = [f"Handoff tier: {tier}"]
    if pf.get("compose") == "missing":
        parts.append("compose folder missing on disk")
    if pf.get("appdata") == "missing":
        parts.append("appdata missing")
    if not pf.get("containers_running") and str(spec_result.get("continue_mode", "")).startswith("compose"):
        parts.append("no containers running")
    drill = (spec_result.get("drill_down") or {}).get("required") or []
    if drill:
        parts.append(f"load {', '.join(drill)} before redeploy")
    if validation.get("warnings"):
        parts.append(f"{len(validation['warnings'])} spec warning(s)")
    return "; ".join(parts)


def _message_count(chat_id: int) -> int:
    conn = sqlite3.connect(db_file())
    cur = conn.cursor()
    cur.execute("SELECT COUNT(*) FROM messages WHERE chat_id = ?", (chat_id,))
    n = cur.fetchone()[0]
    conn.close()
    return n


def main() -> None:
    parser = argparse.ArgumentParser(description="Post-save pipeline for Wolf Leader")
    parser.add_argument("--session-id")
    parser.add_argument("--chat-id", type=int)
    parser.add_argument("--no-sync", action="store_true")
    parser.add_argument("--force-relink", action="store_true")
    parser.add_argument("--root", type=Path, default=TRANSCRIPTS_ROOT)
    args = parser.parse_args()

    if not args.session_id and not args.chat_id:
        parser.error("Provide --session-id or --chat-id")

    result = post_save_pipeline(
        session_id=args.session_id,
        chat_id=args.chat_id,
        sync=not args.no_sync,
        root=args.root,
        force_relink=args.force_relink,
    )
    print(json.dumps(result, indent=2))
    if not result.get("ok"):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
