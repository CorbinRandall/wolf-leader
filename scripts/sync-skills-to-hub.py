#!/usr/bin/env python3
"""Publish user-authored portable skills to a Wolf Leader skill library."""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

IGNORED_PARTS = {".git", ".DS_Store", "__pycache__"}


def default_skill_roots() -> list[Path]:
    home = Path.home()
    configured = os.environ.get("CODEX_HOME")
    roots = [Path(configured) / "skills"] if configured else []
    roots.extend([home / ".codex" / "skills", home / ".agents" / "skills", home / ".cursor" / "skills"])
    unique: list[Path] = []
    for root in roots:
        resolved = root.expanduser()
        if resolved not in unique:
            unique.append(resolved)
    return unique


def discover_skills(roots: list[Path]) -> dict[str, Path]:
    skills: dict[str, Path] = {}
    for root in roots:
        if not root.is_dir():
            continue
        for path in sorted(root.iterdir()):
            if path.name.startswith(".") or not path.is_dir() or not (path / "SKILL.md").is_file():
                continue
            skills.setdefault(path.name, path)
    return skills


def archive_skill(path: Path) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file_path in sorted(path.rglob("*")):
            if (
                not file_path.is_file()
                or file_path.is_symlink()
                or any(part in IGNORED_PARTS for part in file_path.relative_to(path).parts)
            ):
                continue
            archive.write(file_path, f"{path.name}/{file_path.relative_to(path).as_posix()}")
    return buffer.getvalue()


def publish_skill(hub: str, name: str, path: Path) -> dict:
    access_token = os.environ.get("IDE_STORAGE_SKILLS_WRITE_TOKEN", "").strip()
    if access_token and urllib.parse.urlsplit(hub).scheme.lower() != "https":
        raise RuntimeError("Use an HTTPS --hub URL when IDE_STORAGE_SKILLS_WRITE_TOKEN is set")
    payload = json.dumps(
        {
            "name": name,
            "archive_base64": base64.b64encode(archive_skill(path)).decode("ascii"),
            "overwrite": True,
            "access_token": access_token,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        f"{hub.rstrip('/')}/api/skills/import",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{name}: hub returned HTTP {exc.code}: {detail}") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hub", default=os.environ.get("WOLF_LEADER_API"), help="Wolf Leader base URL")
    parser.add_argument("--skills-dir", action="append", type=Path, help="Skill root to scan; may be repeated")
    parser.add_argument("--dry-run", action="store_true", help="List discovered skills without uploading")
    args = parser.parse_args()

    roots = args.skills_dir or default_skill_roots()
    skills = discover_skills(roots)
    if not skills:
        print("No portable user skills found", file=sys.stderr)
        return 1
    if not args.hub and not args.dry_run:
        parser.error("--hub or WOLF_LEADER_API is required")

    for name, path in skills.items():
        if args.dry_run:
            print(f"{name}\t{path}")
            continue
        result = publish_skill(args.hub, name, path)
        skill = result.get("skill") or {}
        print(f"Published {skill.get('name', name)} ({skill.get('file_count', '?')} files) from {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
