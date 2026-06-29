#!/usr/bin/env python3
"""Create a new Wolf Leader project and save the current Cursor session to it."""
from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import urllib.error
from pathlib import Path

_SCRIPT_DIR = Path(__file__).resolve().parent
_SAVE_PY = _SCRIPT_DIR.parent.parent / "save" / "scripts" / "save-session.py"


def _load_save_module():
    spec = importlib.util.spec_from_file_location("save_session", _SAVE_PY)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load save helper: {_SAVE_PY}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def slugify(text: str) -> str:
    s = text.lower().strip()
    s = re.sub(r"[^\w\s-]", "", s)
    s = re.sub(r"[\s_]+", "-", s).strip("-")
    return (s[:64] or "new-project")


def title_from_slug(slug: str) -> str:
    return " ".join(word.capitalize() for word in slug.split("-") if word)


def ensure_project(
    save,
    api: str,
    *,
    slug: str,
    name: str,
    description: str | None = None,
) -> tuple[int, bool]:
    projects = save.api_json("GET", f"{api}/api/projects")
    for project in projects.get("projects") or []:
        if project.get("slug") == slug:
            return int(project["id"]), False

    workspace = os.environ.get("CURSOR_WORKSPACE") or str(Path.cwd())
    body: dict[str, str] = {"name": name, "slug": slug, "path": workspace}
    if description:
        body["description"] = description
    created = save.api_json("POST", f"{api}/api/projects", body)
    return int(created["id"]), True


def save_new_project(
    save,
    api: str,
    *,
    project_id: int,
    slug: str,
    session_id: str | None,
    root_hint: Path | None,
) -> dict:
    sid, path = save.find_transcript(session_id, root_hint=root_hint)
    if not path:
        raise RuntimeError("No local Cursor transcript found under ~/.cursor/projects")

    messages = save.parse_transcript(path)
    if not messages:
        raise RuntimeError(f"Transcript empty: {path}")

    title = save.title_from_messages(messages)
    workspace = os.environ.get("CURSOR_WORKSPACE") or str(Path.cwd())

    try:
        report = save.api_json(
            "POST",
            f"{api}/api/save-project",
            {
                "slug": slug,
                "title": title,
                "workspace_path": workspace,
                "session_id": sid,
                "messages": messages,
            },
            timeout=180,
        )
        if report.get("ok"):
            report["source"] = report.get("source") or "save_project_messages"
            report["project_slug"] = report.get("project_slug") or slug
            return report
    except urllib.error.HTTPError:
        pass

    created = save.api_json(
        "POST",
        f"{api}/api/chats",
        {
            "title": title,
            "workspace_path": workspace,
            "device_name": os.environ.get("WOLF_LEADER_DEVICE") or "cursor-client",
            "session_id": sid,
            "content": f"New project save: {len(messages)} messages from local transcript",
            "messages": messages,
        },
    )
    chat_id = int(created["id"])
    save.api_json("PUT", f"{api}/api/chats/{chat_id}", {"project_id": project_id})
    distill = save.api_json("POST", f"{api}/api/projects/{project_id}/distill", {})
    save.api_json("PUT", f"{api}/api/chats/{chat_id}", {"status": "archived"})

    brief_url = f"{api}/api/projects/{slug}/agent-brief"
    pickup = None
    if isinstance(distill.get("spec"), dict):
        pickup = distill["spec"].get("pickup")

    return {
        "ok": True,
        "source": "new_project_transcript",
        "session_id": sid,
        "chat_id": chat_id,
        "project_id": project_id,
        "project_slug": slug,
        "project_name": distill.get("name") or title,
        "brief_url": brief_url,
        "pickup_prompt": pickup,
        "summary": (
            f"Saved as new project **{distill.get('name') or slug}** "
            f"({len(messages)} messages). Session archived."
        ),
    }


def propose_from_transcript(save, session_id: str | None, root_hint: Path | None) -> tuple[str, str]:
    sid, path = save.find_transcript(session_id, root_hint=root_hint)
    if path:
        messages = save.parse_transcript(path)
        if messages:
            name = save.title_from_messages(messages)
            return slugify(name), name
    return "new-project", "New Project"


def main() -> int:
    if sys.argv[1:2] == ["--help"] or sys.argv[1:2] == ["-h"]:
        print(
            "Usage: new-project-session.py [SLUG] [NAME] [DESCRIPTION]\n"
            "Creates project if needed, then saves current transcript to that slug.",
            file=sys.stderr,
        )
        return 0

    slug_arg = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else None
    name_arg = sys.argv[2] if len(sys.argv) > 2 else None
    description = sys.argv[3].strip() if len(sys.argv) > 3 else None

    save = _load_save_module()
    api, root_hint = save.load_env()
    session_id = os.environ.get("CURSOR_SESSION_ID")

    try:
        if slug_arg:
            slug = slugify(slug_arg)
            name = name_arg.strip() if name_arg else title_from_slug(slug)
        else:
            slug, name = propose_from_transcript(save, session_id, root_hint)

        project_id, created = ensure_project(
            save, api, slug=slug, name=name, description=description
        )
        result = save.save_via_hub_transcript(api, slug, session_id)
        if result is None:
            result = save_new_project(
                save,
                api,
                project_id=project_id,
                slug=slug,
                session_id=session_id,
                root_hint=root_hint,
            )
        result["project_created"] = created
        if created:
            result["summary"] = (
                f"Created project **{name}** (`{slug}`). "
                + (result.get("summary") or "")
            )
        print(json.dumps(result, indent=2))
        return 0 if result.get("ok") else 1
    except urllib.error.HTTPError as exc:
        print(exc.read().decode("utf-8", errors="replace"), file=sys.stderr)
        return 1
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
