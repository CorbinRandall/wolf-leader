#!/usr/bin/env python3
"""Handoff tier, drill-down, and tier-aware pickup prompts — all continue_mode types."""
from __future__ import annotations

import re
from typing import Any

from ide_storage.project_archetypes import host_label_suffix

HANDOFF_TIERS = ("orient", "continue", "rebuild")

_REBUILD_SIGNAL_RE = re.compile(
    r"(?i)\b(docker compose|compose up|rebuild|redeploy|image:|port\s+\d{4}|"
    r"appdata|config\.yaml|\.env|docker-compose|plugin|daemon|ssh|authorized_keys)\b"
)
_INSTALL_CHAT_RE = re.compile(
    r"(?i)\b(install|deploy|compose up|docker compose|setup|rebuild|first run)\b"
)


def _has_archived_install_chat(chats: list[dict[str, Any]]) -> bool:
    for chat in chats:
        if chat.get("status") != "archived":
            continue
        blob = f"{chat.get('title') or ''} {chat.get('content') or ''}"
        if _INSTALL_CHAT_RE.search(blob):
            return True
    return False


def compute_handoff_tier(
    continue_mode: str,
    preflight: dict[str, Any],
    *,
    has_rebuild_steps: bool = False,
    has_services: bool = False,
) -> str:
    observed = preflight.get("observed_deploy_state", "n/a")
    compose = preflight.get("compose", "unknown")
    running = preflight.get("containers_running", False)
    kind = preflight.get("kind", "compose")

    if continue_mode == "compose_maintain":
        # Maintain = do not redeploy; compose folder present is enough to continue
        if compose == "present" or running:
            return "continue"
        return "orient"

    if continue_mode == "compose_deploy":
        compose_present = compose == "present"
        discovered_via = preflight.get("compose_discovered_via")
        stack_gone = observed == "removed" or (not compose_present and not running)

        if running and not compose_present:
            return "orient"

        if stack_gone:
            if compose_present and has_services and has_rebuild_steps:
                return "rebuild"
            return "orient"

        if running and compose_present:
            if observed == "deployed":
                return "continue"
            if discovered_via == "container_labels":
                return "continue"
            return "orient"

        if compose_present:
            return "orient"
        return "orient"

    if continue_mode == "server_daemon":
        if preflight.get("plugin_root") == "present":
            if preflight.get("daemon_running") is False:
                return "orient"
            return "continue"
        return "orient"

    if continue_mode == "client_setup":
        # Always orient — work is on THIS device; server may already be configured
        return "orient"

    if continue_mode == "external_host":
        # Runs on another box; documented as live. Maintain remotely, not redeploy.
        return "continue"

    if continue_mode in ("integration", "investigation"):
        return "orient"

    return "orient"


def drill_down_for_project(
    chats: list[dict[str, Any]],
    *,
    handoff_tier: str,
    message_counts: dict[int, int] | None = None,
    force_if_thin: bool = False,
    memories: list[dict[str, Any]] | None = None,
) -> dict[str, list[str]]:
    """Pick sessions agents should load when checkpoint is thin."""
    required: list[str] = []
    optional: list[str] = []

    include = handoff_tier in ("orient", "rebuild") or force_if_thin
    if not include:
        return {"required": required, "optional": optional}

    scored: list[tuple[int, int, str]] = []
    for chat in chats:
        cid = chat.get("id")
        if not cid:
            continue
        title = (chat.get("title") or "").lower()
        content = (chat.get("content") or "").lower()
        n = (message_counts or {}).get(cid, 0)
        score = n
        if _REBUILD_SIGNAL_RE.search(title + " " + content):
            score += 50
        if chat.get("status") == "archived":
            score += 10
        scored.append((score, cid, chat.get("title") or f"Session {cid}"))

    scored.sort(reverse=True)
    for score, cid, _title in scored[:3]:
        if score < 5:
            continue
        ref = f"chat:{cid}"
        if not required:
            required.append(ref)
        else:
            optional.append(ref)

    return {"required": required[:2], "optional": optional[:3]}


def pickup_for_tier(
    name: str,
    slug: str,
    *,
    handoff_tier: str,
    continue_mode: str,
    brief_url: str,
    preflight: dict[str, Any] | None = None,
) -> str:
    pf = preflight or {}
    gap_parts: list[str] = []

    if continue_mode in ("compose_deploy", "compose_maintain"):
        if pf.get("compose") == "missing":
            gap_parts.append("compose folder missing")
        if pf.get("appdata") == "missing":
            gap_parts.append("appdata missing")
        if not pf.get("containers_running") and pf.get("docker_check") == "ok":
            gap_parts.append("no containers running")
    elif continue_mode == "server_daemon":
        if pf.get("plugin_root") == "missing":
            gap_parts.append("plugin root missing")
        if pf.get("daemon_running") is False:
            gap_parts.append("daemon not running")
    elif continue_mode == "client_setup":
        paths = pf.get("server_paths") or []
        if paths and not any(p.get("status") == "present" for p in paths):
            gap_parts.append("server paths not verified on disk")

    gap = f" ({'; '.join(gap_parts)})" if gap_parts else ""
    on_host = host_label_suffix()

    if handoff_tier == "orient":
        if continue_mode == "client_setup":
            return (
                f"Continue {name} — set up THIS device/client{on_host}. "
                f"Server may already be configured; load checkpoint: {brief_url}"
            )
        if continue_mode == "server_daemon":
            return (
                f"Continue {name} plugin/daemon tuning{on_host} (not Docker Compose){gap}. "
                f"Load checkpoint: {brief_url}"
            )
        if continue_mode == "investigation":
            return (
                f"Resume {name} investigation{on_host}{gap}. "
                f"Load checkpoint and drill_down sessions: {brief_url}"
            )
        if continue_mode == "integration":
            return (
                f"Continue {name} external integration setup{on_host}{gap}. "
                f"Load checkpoint: {brief_url}"
            )
        return (
            f"Load {name} checkpoint for orientation{gap} — verify on_disk before acting. "
            f"Check drill_down sessions if redeploying. Load: {brief_url}"
        )

    if handoff_tier == "rebuild":
        return (
            f"Rebuild {name}{on_host} from SPEC + drill_down sessions{gap}. "
            f"Load: {brief_url}"
        )

    if handoff_tier == "continue":
        if continue_mode == "external_host":
            host = pf.get("external_host") or "a remote host"
            url = pf.get("external_url")
            loc = pf.get("external_path")
            where = f" at {loc}" if loc else ""
            link = f" ({url})" if url else ""
            return (
                f"Continue {name} — runs on {host}{where} as a systemd service{link}; "
                f"maintain remotely, do NOT redeploy locally. Load: {brief_url}"
            )
        if continue_mode == "compose_maintain":
            return (
                f"Continue {name}{on_host} — stack is running; fix/maintain only, do not redeploy. "
                f"Load: {brief_url}"
            )
        if continue_mode == "server_daemon":
            return (
                f"Continue {name} daemon tuning{on_host} — plugin present, maintain only. "
                f"Load: {brief_url}"
            )
        return (
            f"Continue {name}{on_host} — environment appears healthy; maintain only. "
            f"Load: {brief_url}"
        )

    return f"Work on {name}{on_host}. Load: {brief_url}"


def parse_spec_handoff(spec_yaml: str) -> dict[str, Any]:
    """Lightweight parse of handoff fields from SPEC text."""
    out: dict[str, Any] = {}
    m = re.search(r"^handoff_tier:\s*(\w+)", spec_yaml, re.MULTILINE)
    if m:
        out["handoff_tier"] = m.group(1)
    m = re.search(r"^observed_deploy_state:\s*(\w+)", spec_yaml, re.MULTILINE)
    if m:
        out["observed_deploy_state"] = m.group(1)
    in_drill = False
    in_required = False
    in_optional = False
    for line in spec_yaml.splitlines():
        if line.strip() == "drill_down:":
            in_drill = True
            continue
        if not in_drill:
            continue
        if re.match(r"^\s{2}required:\s*$", line):
            in_required = True
            in_optional = False
            continue
        if re.match(r"^\s{2}optional:\s*$", line):
            in_optional = True
            in_required = False
            continue
        if in_drill and re.match(r"^\S", line) and not line.startswith("  "):
            break
        m = re.match(r'^\s+-\s+"?chat:(\d+)"?', line)
        if m:
            ref = f"chat:{m.group(1)}"
            if in_optional:
                out.setdefault("drill_down_optional", []).append(ref)
            else:
                out.setdefault("drill_down_required", []).append(ref)
    return out
