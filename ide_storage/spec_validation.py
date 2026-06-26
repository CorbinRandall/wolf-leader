#!/usr/bin/env python3
"""Validate SPEC.yaml content per continue_mode."""
from __future__ import annotations

import re
from typing import Any

# Required YAML keys (presence in text) per continue_mode
REQUIRED: dict[str, list[str]] = {
    "compose_deploy": ["compose", "paths"],
    "compose_maintain": ["compose", "paths"],
    "server_daemon": ["plugin_root"],
    "client_setup": ["server_paths"],
    "integration": [],  # soft — integrations are often web-UI config with no local paths
    "investigation": [],  # soft — findings OR next_checks
    "external_host": ["external_service"],
}

RECOMMENDED: dict[str, list[str]] = {
    "compose_deploy": ["decisions", "pickup"],
    "compose_maintain": ["decisions", "pickup"],
    "server_daemon": ["policy", "pickup"],
    "client_setup": ["constraints", "pickup"],
    "integration": ["decisions", "pickup"],
    "investigation": ["findings", "pickup"],
    "external_host": ["pickup"],
}


def _has_key(spec_yaml: str, key: str) -> bool:
    return bool(re.search(rf"^{re.escape(key)}:", spec_yaml, re.MULTILINE))


def _has_list_items(spec_yaml: str, key: str) -> bool:
    if not _has_key(spec_yaml, key):
        return False
    m = re.search(rf"^{re.escape(key)}:\s*\n((?:\s+-\s+.+\n?)+)", spec_yaml, re.MULTILINE)
    return bool(m and m.group(1).strip())


def validate_spec(spec_yaml: str, continue_mode: str) -> dict[str, Any]:
    """Return validation report. valid=True if no errors (warnings OK)."""
    errors: list[str] = []
    warnings: list[str] = []

    if not spec_yaml or not spec_yaml.strip():
        return {"valid": False, "errors": ["SPEC is empty"], "warnings": []}

    for key in ("name", "slug", "continue_mode", "pickup", "brief_url", "handoff_tier"):
        if not _has_key(spec_yaml, key):
            errors.append(f"Missing required envelope key: {key}")

    if _has_key(spec_yaml, "handoff_tier"):
        tier = re.search(r"^handoff_tier:\s*(\w+)", spec_yaml, re.MULTILINE)
        if tier and tier.group(1) not in ("orient", "continue", "rebuild"):
            warnings.append(f"Unknown handoff_tier: {tier.group(1)}")

    if not _has_key(spec_yaml, "on_disk"):
        warnings.append(f"{continue_mode} missing on_disk preflight block")

    if continue_mode == "server_daemon" and not _has_key(spec_yaml, "plugin_root"):
        errors.append("server_daemon requires plugin_root")

    if continue_mode == "client_setup" and not _has_list_items(spec_yaml, "server_paths"):
        if not re.search(r"server_paths:", spec_yaml):
            warnings.append("client_setup SPEC has no server_paths block")
    if continue_mode == "client_setup":
        if re.search(r"(?i)\b(sleep|s3[\s_-]?sleep|docker compose)\b", spec_yaml):
            if _has_list_items(spec_yaml, "steps") or "client_procedure:" in spec_yaml:
                warnings.append("client_setup SPEC may contain unrelated non-SSH steps")

    if continue_mode not in REQUIRED:
        warnings.append(f"Unknown continue_mode: {continue_mode}")
        return {"valid": len(errors) == 0, "errors": errors, "warnings": warnings}

    # Mode-required: at least one of the listed keys with content
    req_keys = REQUIRED[continue_mode]
    if req_keys:
        if not any(_has_list_items(spec_yaml, k) or _has_key(spec_yaml, k) for k in req_keys):
            errors.append(
                f"{continue_mode} requires at least one of: {', '.join(req_keys)}"
            )

    if continue_mode == "investigation":
        if not (_has_list_items(spec_yaml, "findings") or _has_list_items(spec_yaml, "next_checks")):
            warnings.append("investigation SPEC has no findings or next_checks yet")

    for key in RECOMMENDED.get(continue_mode, []):
        if not (_has_list_items(spec_yaml, key) or _has_key(spec_yaml, key)):
            warnings.append(f"Recommended key missing or empty: {key}")

    if continue_mode == "compose_deploy" and _has_key(spec_yaml, "deploy_state"):
        if "deploy_state: removed" in spec_yaml and not _has_list_items(spec_yaml, "rebuild"):
            warnings.append("deploy_state is removed but no rebuild steps listed")

    return {
        "valid": len(errors) == 0,
        "errors": errors,
        "warnings": warnings,
        "continue_mode": continue_mode,
    }
