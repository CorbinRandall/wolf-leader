"""Human-facing project overview for the web UI.

This is what a person with no context should read: what the project is for and
how it evolved. Agent handoff / “where we left off” lives elsewhere (SPEC pickup,
where_we_left_off metadata) and must not dominate this paragraph.
"""
from __future__ import annotations

import json
import re
from typing import Any, Optional

# Plain-language stories when DB/SPEC overview is thin. Prefer narrative over
# deployment jargon so the project page reads like a short project blurb.
SLUG_STORIES: dict[str, str] = {
    "samsung-server": (
        "Turns an old Samsung Galaxy phone into a small always-on home server — "
        "SSH access, UPS-aware backup hub, and a lightweight Docker dashboard that "
        "can also run on Proxmox. Started as phone tooling; grew into the shared "
        "Go hub (corbox-lite) used for both the phone backup and the main Proxmox dashboard."
    ),
    "logitech-g-hub": (
        "Started as a simple toolkit to pull and adjust Logitech G502 presets without "
        "relying on Logitech G HUB. Grew into a fuller ownership app: onboard preset "
        "management, blocking unwanted G HUB updates, and recovering from macOS HID/USB wedges."
    ),
    "docker-dashboard": (
        "Homelab “Server Hub” — a small web page to wake the server, see Docker apps, "
        "and jump into services. Began as a Python stack on Proxmox; now centered on the "
        "Go corbox-lite hub, with the phone build as an independent backup."
    ),
    "ide-storage": (
        "Wolf Leader is the self-hosted memory hub for AI project work — projects, "
        "session logbook, typed memories, and agent briefs so a new chat can pick up "
        "without re-explaining the whole homelab."
    ),
    "wolf-leader": (
        "Wolf Leader is the self-hosted memory hub for AI project work — projects, "
        "session logbook, typed memories, and agent briefs so a new chat can pick up "
        "without re-explaining the whole homelab."
    ),
    "imessage-archive": (
        "Self-hosted Apple Messages archive: Mac agents export chats, Unraid stores "
        "and indexes them, and a web UI lets you browse and search years of iMessage "
        "history (including attachments)."
    ),
    "s3-sleep": (
        "Hardens Unraid S3 sleep so the server sleeps when you’re really idle — smarter "
        "activity checks, Docker awareness, and recovery hooks — instead of staying awake "
        "for noise like idle SSH or background sync."
    ),
    "ssh-passwordless": (
        "Passwordless SSH from Cursor, Mac, and other clients into the homelab hosts, "
        "so agents and you can work without typing passwords every session."
    ),
    "tailscale": (
        "Homelab Tailscale mesh so Macs can reach LAN services remotely via the Proxmox "
        "subnet router — durable remote access without exposing every service to the internet."
    ),
    "custom-server-url": (
        "Friendly hostnames and reverse-proxy wiring (NPM, Caddy, local DNS) so services "
        "are reachable by name — separate from the container-links dashboard."
    ),
    "cache-drive": "Unraid cache drive inspection and maintenance.",
}

# Backward-compatible alias used by older tests/imports.
SLUG_HINTS = SLUG_STORIES

_GENERIC_OVERVIEW_RE = re.compile(
    r"^(compose stack:\s*\S+|homelab project [“\"'].+[”\"']\.?)$",
    re.I,
)
_AGENT_JARGON_RE = re.compile(
    r"(?i)\b(handoff_tier|pickup_override|agent-brief|SPEC\.yaml|where we left off|"
    r"do not redeploy|orient first|verify what.?s on disk)\b"
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


def _clean_prose(text: str, *, max_len: int = 480) -> str:
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


def _story_from_memories(memories: list[dict[str, Any]], *, max_len: int = 420) -> str:
    """Build a short origin→now blurb from goal/decision memories when nothing else exists."""
    useful: list[str] = []
    for m in memories or []:
        typ = (m.get("type") or "").lower()
        if typ not in ("goal", "decision"):
            continue
        content = re.sub(r"\s+", " ", (m.get("content") or "").strip())
        if len(content) < 40 or _AGENT_JARGON_RE.search(content):
            continue
        # Skip ultra-technical one-liners full of paths/IPs.
        slash_n = content.count("/")
        if slash_n >= 3 and len(content) < 160:
            continue
        useful.append(content)
        if len(useful) >= 6:
            break
    if not useful:
        return ""
    if len(useful) == 1:
        return _clean_prose(useful[0], max_len=max_len)
    first = useful[-1] if len(useful) > 1 else useful[0]  # older often later in recall lists
    # Prefer earliest-looking: memories are usually newest-first from recall.
    oldest = useful[-1]
    newest = useful[0]
    if oldest[:80].lower() == newest[:80].lower():
        return _clean_prose(newest, max_len=max_len)
    blended = (
        f"Started around: {_clean_prose(oldest, max_len=180).rstrip('.')} "
        f"More recently: {_clean_prose(newest, max_len=220)}"
    )
    return _clean_prose(blended, max_len=max_len)


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
        if isinstance(val, str) and len(val.strip()) >= 40:
            return _clean_prose(val.strip())

    story = SLUG_STORIES.get(slug, "")
    semantic = meta.get("semantic_descriptor")
    if isinstance(semantic, str) and len(semantic.strip()) >= 40:
        sem = _clean_prose(semantic.strip(), max_len=480)
        # Prefer curated story when semantic is still deploy-ops dense.
        if story and (sem.count("/") + sem.count(":")) >= 6:
            return story
        return sem

    if overview and not _GENERIC_OVERVIEW_RE.match(overview.strip()):
        # Short DB descriptions are fine as the lead sentence; expand with story if we have one.
        ov = _clean_prose(overview, max_len=280)
        if story and len(overview) < 100:
            return _clean_prose(f"{ov.rstrip('.')}. {story}", max_len=480)
        return ov

    if story:
        return story

    from_mem = _story_from_memories(memories or [])
    if from_mem:
        return from_mem

    label = slug.replace("-", " ")
    return f"Homelab project “{label}” — open the logbook below for what’s been done."


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
    max_len: int = 520,
) -> str:
    """Natural-language paragraph: what this project is for (human UI).

    Intentionally ignores agent pickup / where_we_left_off and continue-mode
    instructions — those belong in the agent brief, not the project blurb.
    """
    # Unused agent-context kwargs kept for call-site compatibility.
    _ = (continue_mode, handoff_tier, deploy_state, preflight, archived_recent_sessions, active_sessions)

    slug = (project.get("slug") or f"project-{project.get('id', 0)}").strip()
    meta = _parse_meta(project)
    overview = _extract_overview(project, spec_yaml=spec_yaml, project_md=project_md)
    text = _identity_story(slug, overview, meta=meta, memories=memories)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > max_len:
        text = text[: max_len - 1].rstrip() + "…"
    return text
