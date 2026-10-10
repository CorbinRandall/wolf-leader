#!/usr/bin/env python3
"""Install post-commit git hooks on compose project folders → Wolf Leader remember."""
from __future__ import annotations

import argparse
import json
import os
import stat
from pathlib import Path

from ide_storage.db import db_conn

HOOK_NAME = "post-commit"
HOOK_MARKER = "# wolf-leader-post-commit"
API_URL = os.environ.get("IDE_STORAGE_URL", "http://127.0.0.1:6971").rstrip("/")


def _find_git_root(start: Path) -> Path | None:
    cur = start.resolve()
    for _ in range(8):
        if (cur / ".git").is_dir():
            return cur
        if cur.parent == cur:
            break
        cur = cur.parent
    return None


def _hook_body(project_id: int, slug: str) -> str:
    return f"""#!/bin/sh
{HOOK_MARKER}
# Auto-remember compose commits for project {slug} (#{project_id})
API="{API_URL}"
MSG=$(git log -1 --pretty=%B 2>/dev/null | head -c 500)
if [ -z "$MSG" ]; then exit 0; fi
FILES=$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null | head -5 | tr '\\n' ', ' | sed 's/,$//')
CONTENT="Git commit: $MSG"
[ -n "$FILES" ] && CONTENT="$CONTENT (files: $FILES)"
curl -sf --max-time 8 -X POST "$API/api/memories" \\
  -H 'Content-Type: application/json' \\
  -d "{{\\"project_id\\": {project_id}, \\"type\\": \\"decision\\", \\"content\\": \\"$CONTENT\\"}}" >/dev/null 2>&1 || true
exit 0
"""


def install_hooks(*, dry_run: bool = False) -> list[dict]:
    results: list[dict] = []
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, slug, name, compose_path, path FROM projects
            WHERE COALESCE(status, 'active') != 'archived'
            ORDER BY id
            """
        )
        projects = [dict(r) for r in cur.fetchall()]

    seen_roots: set[str] = set()
    for proj in projects:
        compose = proj.get("compose_path") or proj.get("path") or ""
        if not compose or not os.path.isdir(compose):
            results.append({"slug": proj.get("slug"), "action": "skipped", "reason": "no compose_path"})
            continue

        git_root = _find_git_root(Path(compose))
        if not git_root:
            results.append({"slug": proj.get("slug"), "action": "skipped", "reason": "not a git repo"})
            continue

        root_s = str(git_root)
        if root_s in seen_roots:
            results.append({"slug": proj.get("slug"), "action": "skipped", "reason": "hook already installed for repo"})
            continue

        hooks_dir = git_root / ".git" / "hooks"
        hook_path = hooks_dir / HOOK_NAME
        body = _hook_body(proj["id"], proj.get("slug") or f"project-{proj['id']}")

        if dry_run:
            results.append({"slug": proj.get("slug"), "action": "dry_run", "hook_path": str(hook_path)})
            seen_roots.add(root_s)
            continue

        hooks_dir.mkdir(parents=True, exist_ok=True)
        if hook_path.is_file():
            existing = hook_path.read_text(encoding="utf-8", errors="replace")
            if HOOK_MARKER in existing:
                results.append({"slug": proj.get("slug"), "action": "exists", "hook_path": str(hook_path)})
                seen_roots.add(root_s)
                continue
            body = existing.rstrip() + "\n\n" + body

        hook_path.write_text(body, encoding="utf-8")
        hook_path.chmod(hook_path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        results.append({"slug": proj.get("slug"), "action": "installed", "hook_path": str(hook_path)})
        seen_roots.add(root_s)

    return results


def main() -> None:
    parser = argparse.ArgumentParser(description="Install git post-commit hooks for compose projects")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    results = install_hooks(dry_run=args.dry_run)
    print(json.dumps({"installed": len([r for r in results if r.get("action") == "installed"]), "results": results}, indent=2))


if __name__ == "__main__":
    main()
