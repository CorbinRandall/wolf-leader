"""One-paragraph human overview for project pages — what this is and where work left off."""
from __future__ import annotations

import re
from typing import Any, Optional

# Plain-language identity when DB/SPEC overview is generic or missing.
SLUG_HINTS: dict[str, str] = {
    "docker-dashboard": (
        "A small homelab web page that lists running Docker containers "
        "with clickable links — the “Docker Apps” dashboard, not reverse-proxy work."
    ),
    "custom-server-url": (
        "Friendly URLs and reverse-proxy setup (NPM, Caddy, local DNS) so services "
        "are reachable by name — not the container-links dashboard."
    ),
    "wolf-leader": (
        "Central hub for AI project storage — agent briefs, memories, and session handoff."
    ),
    "s3-sleep": "Unraid S3 sleep hardening — activity checks, watchdog, post-wake hooks.",
    "ssh-passwordless": "Passwordless SSH from clients (Cursor, Mac, etc.) to the server.",
    "cache-drive": "Unraid cache drive inspection and maintenance.",
}

_GENERIC_OVERVIEW_RE = re.compile(
    r"^compose stack:\s*\S+$",
    re.I,
)


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


def _yaml_list_items(spec_yaml: str, key: str, limit: int = 2) -> list[str]:
    if not spec_yaml:
        return []
    lines = spec_yaml.splitlines()
    out: list[str] = []
    in_block = False
    for line in lines:
        if re.match(rf"^{re.escape(key)}:\s*$", line):
            in_block = True
            continue
        if in_block:
            if line and not line.startswith(" "):
                break
            m = re.match(r'^\s+-\s+"(.*)"\s*$', line)
            if m:
                out.append(m.group(1).replace('\\"', '"'))
                if len(out) >= limit:
                    break
    return out


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


def _identity_sentence(slug: str, overview: str) -> str:
    hint = SLUG_HINTS.get(slug, "")
    if hint:
        if not overview or _GENERIC_OVERVIEW_RE.match(overview.strip()):
            return hint
        if overview.strip().lower() == hint.split("—")[0].strip().lower()[: len(overview)]:
            return hint
    if overview:
        return overview.rstrip(".") + "."
    if hint:
        return hint
    return f"Homelab project “{slug.replace('-', ' ')}”."


def _work_sentence(
    *,
    continue_mode: str,
    handoff_tier: str,
    deploy_state: str,
    preflight: dict[str, Any],
) -> str:
    mode = continue_mode or ""
    tier = handoff_tier or ""
    deploy = (deploy_state or "").lower()
    pf = preflight or {}

    if mode == "client_setup":
        return "Client-device setup — SSH keys, Cursor, or other tooling on your machine."
    if mode == "server_daemon":
        running = pf.get("daemon_running")
        if running is True:
            return "Unraid plugin/daemon is running — policy and code changes, not Docker Compose."
        if running is False:
            return "Plugin/daemon work — service may be stopped; check the brief before editing."
        return "Unraid plugin or daemon tuning — not a Docker Compose stack."
    if mode == "integration":
        if tier == "rebuild":
            return "External integration — topology may have changed; verify live state before acting."
        return "External wiring (DNS, reverse proxy, OAuth) — no compose folder tied to this project."
    if mode == "investigation":
        return "Diagnostic or tuning work on the host or a service — see findings in the brief."
    if mode.startswith("compose"):
        containers = pf.get("containers") or []
        compose = pf.get("compose", "")
        if tier == "continue" or deploy == "deployed":
            n = len(containers)
            extra = f" ({n} container{'s' if n != 1 else ''} running)" if n else ""
            return f"Stack is deployed and healthy{extra} — maintain and fix, don’t redeploy unless asked."
        if compose == "missing" or tier == "rebuild":
            return "Compose may be missing or incomplete — read archived sessions before redeploying."
        if tier == "orient":
            return "Verify what’s on disk and in archived sessions before changing the stack."
        return "Docker Compose project — check on_disk status in the brief before acting."
    if tier == "continue":
        return "Pick up where the last session left off."
    if tier == "orient":
        return "Orient first — confirm live state matches the brief."
    return ""


def _recent_sentence(
    *,
    archived_recent_sessions: list[dict[str, Any]],
    active_sessions: list[dict[str, Any]],
    blockers: list[str],
) -> str:
    if archived_recent_sessions:
        s = archived_recent_sessions[0]
        title = (s.get("title") or f"session #{s.get('id', '?')}").strip()
        if title.lower().startswith("chat #"):
            title = title[6:].strip() or title
        when = s.get("updated_at") or ""
        date_bit = ""
        if when and len(when) >= 10:
            date_bit = f" ({when[:10]})"
        return f"Last checkpointed work{date_bit}: {title}."
    if active_sessions:
        s = active_sessions[0]
        title = (s.get("title") or f"chat #{s.get('id', '?')}").strip()
        return f"Active session in progress: {title}."
    if blockers:
        b = blockers[0]
        if len(b) > 120:
            b = b[:117].rstrip() + "…"
        return f"Open issue: {b}"
    return ""


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
    max_len: int = 480,
) -> str:
    """Natural-language paragraph: what this project is + current work context."""
    slug = (project.get("slug") or f"project-{project.get('id', 0)}").strip()
    overview = _extract_overview(project, spec_yaml=spec_yaml, project_md=project_md)
    parts = [
        _identity_sentence(slug, overview),
        _work_sentence(
            continue_mode=continue_mode or "",
            handoff_tier=handoff_tier or "",
            deploy_state=deploy_state or "",
            preflight=preflight or {},
        ),
        _recent_sentence(
            archived_recent_sessions=archived_recent_sessions or [],
            active_sessions=active_sessions or [],
            blockers=_yaml_list_items(spec_yaml, "blockers", limit=1),
        ),
    ]
    text = " ".join(p.strip() for p in parts if p and p.strip())
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > max_len:
        text = text[: max_len - 1].rstrip() + "…"
    return text
