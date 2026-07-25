"""Human-facing project overview for the web UI (Project tab).

Super-basic “what is this project?” copy — not session status, not agent pickup.
"""
from __future__ import annotations

import json
import re
from typing import Any, Optional

# One or two plain sentences: what we’re actually doing. Keep it non-technical.
SLUG_STORIES: dict[str, str] = {
    "samsung-server": (
        "Running an old Samsung phone as a small home server — for SSH access, "
        "backups, and a simple dashboard."
    ),
    "logitech-g-hub": (
        "Building tools to work with Logitech G Hub yourself — so you can use, "
        "save, and own your mouse presets without depending on Logitech’s app."
    ),
    "docker-dashboard": (
        "A simple home-server hub page — wake the machine, see apps, and open services."
    ),
    "ide-storage": (
        "Wolf Leader: a place to keep project memory for AI chats — what each project "
        "is, what’s been done, and how to pick up again later."
    ),
    "wolf-leader": (
        "Wolf Leader: a place to keep project memory for AI chats — what each project "
        "is, what’s been done, and how to pick up again later."
    ),
    "imessage-archive": (
        "Backing up and searching Apple Messages on your own server, with a web browser UI."
    ),
    "s3-sleep": (
        "Making the Unraid server sleep when you’re actually idle — and wake reliably when needed."
    ),
    "ssh-passwordless": (
        "Setting up passwordless SSH so your Mac and Cursor can reach the servers without typing a password each time."
    ),
    "tailscale": (
        "Remote access to the home network via Tailscale, so Macs can reach LAN services away from home."
    ),
    "custom-server-url": (
        "Friendly names and reverse-proxy wiring so home services are reachable by hostname."
    ),
    "cache-drive": "Looking after the Unraid cache drive.",
}

# Backward-compatible alias.
SLUG_HINTS = SLUG_STORIES

_GENERIC_OVERVIEW_RE = re.compile(
    r"^(compose stack:\s*\S+|homelab project [“\"'].+[”\"']\.?|"
    r".*\bownership toolkit\b.*|"
    r"g502 ownership toolkit.*)$",
    re.I,
)
_AGENT_JARGON_RE = re.compile(
    r"(?i)\b(handoff_tier|pickup_override|agent-brief|SPEC\.yaml|where we left off|"
    r"do not redeploy|orient first|verify what.?s on disk|bin/deploy|"
    r"192\.168\.|LXC\s*\d+)\b"
)


def _parse_meta(project: dict[str, Any]) -> dict[str, Any]:
    raw = project.get("metadata")
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str) and raw.strip():
        try:
            parsed = json.loads(raw)
            return parsed if isinstance(parsed, dict) else {}
        except json.JSONDecodeError:
            return {}
    return {}


def _yaml_field(spec_yaml: str, key: str) -> str:
    if not spec_yaml:
        return ""
    m = re.search(rf"^{re.escape(key)}:\s*(.+)$", spec_yaml, re.MULTILINE)
    if not m:
        return ""
    raw = m.group(1).strip()
    if raw.startswith('"') and raw.endswith('"'):
        return raw[1:-1].replace('\\"', '"')
    return raw


def _clean_prose(text: str, *, max_len: int = 320) -> str:
    t = re.sub(r"\s+", " ", (text or "").strip())
    t = re.sub(r"\*\*?|`+", "", t)
    if len(t) > max_len:
        cut = t[: max_len - 1].rsplit(" ", 1)[0].rstrip(" ,.;:")
        t = (cut or t[: max_len - 1]).rstrip() + "…"
    if t and t[-1] not in ".!?…":
        t += "."
    return t


def _extract_overview(
    project: dict[str, Any],
    *,
    spec_yaml: str = "",
    project_md: str = "",
) -> str:
    overview = (project.get("description") or "").strip()
    spec_overview = _yaml_field(spec_yaml, "overview")
    if spec_overview:
        overview = spec_overview
    if project_md and "## Overview" in project_md:
        m = re.search(r"## Overview\s*\n+(.*?)(?=\n## |\Z)", project_md, re.DOTALL)
        if m:
            chunk = m.group(1).strip()
            if chunk and chunk != "_No overview yet._":
                overview = chunk
    return overview


def _story_from_memories(memories: list[dict[str, Any]], *, max_len: int = 280) -> str:
    for m in memories or []:
        typ = (m.get("type") or "").lower()
        if typ not in ("goal", "decision"):
            continue
        content = re.sub(r"\s+", " ", (m.get("content") or "").strip())
        if len(content) < 40 or _AGENT_JARGON_RE.search(content):
            continue
        if content.count("/") >= 2:
            continue
        return _clean_prose(content, max_len=max_len)
    return ""


def _identity_story(
    slug: str,
    overview: str,
    *,
    meta: dict[str, Any],
    memories: Optional[list[dict[str, Any]]] = None,
) -> str:
    # Explicit human override wins.
    for key in ("human_overview", "project_story"):
        val = meta.get(key)
        if isinstance(val, str) and len(val.strip()) >= 24:
            return _clean_prose(val.strip())

    # Curated plain-language blurb for known projects (preferred over ops descriptors).
    story = SLUG_STORIES.get(slug, "")
    if story:
        return story

    if overview and not _GENERIC_OVERVIEW_RE.match(overview.strip()):
        if not _AGENT_JARGON_RE.search(overview):
            return _clean_prose(overview, max_len=280)

    semantic = meta.get("semantic_descriptor")
    if isinstance(semantic, str) and len(semantic.strip()) >= 40:
        if not _AGENT_JARGON_RE.search(semantic) and semantic.count("/") < 3:
            return _clean_prose(semantic.strip(), max_len=280)

    from_mem = _story_from_memories(memories or [])
    if from_mem:
        return from_mem

    label = slug.replace("-", " ")
    return f"Homelab project “{label}.”"


def build_purpose_summary(
    project: dict[str, Any],
    *,
    spec_yaml: str = "",
    project_md: str = "",
    continue_mode: Optional[str] = None,
    handoff_tier: Optional[str] = None,
    deploy_state: Optional[str] = None,
    preflight: Optional[dict[str, Any]] = None,
    archived_recent_sessions: Optional[list[dict[str, Any]]] = None,
    active_sessions: Optional[list[dict[str, Any]]] = None,
    memories: Optional[list[dict[str, Any]]] = None,
    max_len: int = 320,
) -> str:
    """Short Project-tab overview: what this project is for."""
    _ = (continue_mode, handoff_tier, deploy_state, preflight, archived_recent_sessions, active_sessions)

    slug = (project.get("slug") or f"project-{project.get('id', 0)}").strip()
    meta = _parse_meta(project)
    overview = _extract_overview(project, spec_yaml=spec_yaml, project_md=project_md)
    text = _identity_story(slug, overview, meta=meta, memories=memories)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > max_len:
        text = text[: max_len - 1].rstrip() + "…"
    return text
