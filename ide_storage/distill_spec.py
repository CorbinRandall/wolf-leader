#!/usr/bin/env python3
"""Build minimal typed SPEC.yaml per project (canonical agent checkpoint)."""
from __future__ import annotations

import json
import os
import re
from datetime import datetime
from pathlib import Path
from typing import Any

from ide_storage.db import db_conn, get_projects_dir
from ide_storage.distill_project import (
    PATH_RE,
    _extract_paths,
    _load_seed_sections,
    _truncate,
)
from ide_storage.markdown_sync import read_project_md, write_agent_brief
from ide_storage.compose_extract import (
    discover_compose_path,
    extract_config_files,
    extract_env_from_compose,
    extract_env_vars,
    merge_services,
)
from ide_storage.memory_ops import is_memory_relevant_to_project
from ide_storage.handoff import (
    _has_archived_install_chat,
    compute_handoff_tier,
    drill_down_for_project,
    pickup_for_tier,
)
from ide_storage.preflight import (
    DAEMON_PROCESS_PATTERNS,
    on_disk_yaml_lines,
    run_preflight,
)
from ide_storage.project_archetypes import get_continue_mode, get_deploy_state, metadata_patch
from ide_storage.spec_validation import validate_spec

SPEC_MAX_CHARS = 3200


def _projects_dir() -> Path:
    return Path(get_projects_dir())


def _yaml_quote(s: str) -> str:
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{s}"'


def _yaml_list(key: str, items: list[str], indent: int = 0) -> list[str]:
    if not items:
        return []
    pad = " " * indent
    lines = [f"{pad}{key}:"]
    for item in items:
        lines.append(f"{pad}  - {_yaml_quote(item[:400])}")
    return lines


def _yaml_env_block(env_vars: list[dict]) -> list[str]:
    if not env_vars:
        return []
    lines = ["env:"]
    for entry in env_vars[:10]:
        lines.append(f"  - var: {entry['var']}")
        lines.append(f"    file: {_yaml_quote(str(entry.get('file', ''))[:200])}")
        lines.append(f"    required: {'true' if entry.get('required') else 'false'}")
    lines.append("secrets_policy: never_store_values")
    return lines


def _yaml_services_block(services: list[dict]) -> list[str]:
    if not services:
        return []
    lines = ["services:"]
    for svc in services[:6]:
        lines.append(f"  - name: {svc.get('name', 'unknown')}")
        if svc.get("image"):
            lines.append(f"    image: {_yaml_quote(str(svc['image'])[:120])}")
        if svc.get("ports"):
            lines.append("    ports:")
            for port in svc["ports"][:4]:
                lines.append(f"      - {_yaml_quote(str(port)[:40])}")
    return lines


def _yaml_drill_down(drill: dict[str, list[str]]) -> list[str]:
    if not drill.get("required") and not drill.get("optional"):
        return []
    lines = ["drill_down:"]
    req = drill.get("required") or []
    opt = drill.get("optional") or []
    if req:
        lines.append("  required:")
        for item in req:
            lines.append(f"    - {_yaml_quote(item[:400])}")
    if opt:
        lines.append("  optional:")
        for item in opt:
            lines.append(f"    - {_yaml_quote(item[:400])}")
    return lines


def _yaml_config_files_block(files: list[dict[str, Any]]) -> list[str]:
    if not files:
        return []
    lines = ["config_files:"]
    for entry in files[:8]:
        path = str(entry.get("path", "")).replace('"', '\\"')
        status = entry.get("status", "unknown")
        lines.append(f'  - path: "{path}"')
        lines.append(f"    status: {status}")
    return lines


def _yaml_persistence_block(preflight: dict[str, Any]) -> list[str]:
    if preflight.get("persistence") == "named_volumes" and preflight.get("named_volumes"):
        lines = ["persistence:", "  model: named_volumes", "  volumes:"]
        for v in preflight["named_volumes"][:8]:
            lines.append(f'    - "{v}"')
        return lines
    if preflight.get("bind_mounts"):
        lines = ["persistence:", "  model: bind_mounts", "  binds:"]
        for b in preflight["bind_mounts"][:6]:
            lines.append(f'    - {_yaml_quote(str(b)[:120])}')
        return lines
    return []


def _compose_context_path(compose: str, slug: str) -> str | None:
    if not compose:
        return None
    ctx = os.path.join(compose, "IDE_CONTEXT.md")
    if os.path.isfile(ctx):
        return ctx
    # compose.manager sibling
    alt = f"/boot/config/plugins/compose.manager/projects/{slug}/IDE_CONTEXT.md"
    if os.path.isfile(alt):
        return alt
    return None


def _client_setup_steps(memories: list[dict], assistant_texts: list[str]) -> tuple[list[str], list[str]]:
    """Return (client_procedure, client_artifacts) for client_setup mode."""
    procedure: list[str] = []
    artifacts: list[str] = []
    ssh_re = re.compile(r"(?i)\b(ssh|authorized_keys|passwordless|public key|id_ed25519|id_rsa|ssh-copy-id)\b")
    noise_re = re.compile(r"(?i)\b(sleep|s3[\s_-]?sleep|stays awake|spun down|port 80|ui connection)\b")
    for m in memories:
        c = (m.get("content") or "").strip()
        if not c or not ssh_re.search(c) or noise_re.search(c):
            continue
        if re.search(r"(?i)\.(command|sh)\b|/root/|/boot/config/ssh", c):
            artifacts.append(c[:300])
        elif len(c) > 30:
            procedure.append(c[:300])
    for text in assistant_texts[:3]:
        for match in re.findall(r"(/[^\s`\"']+(?:authorized_keys|\.command|setup-unraid)[^\s`\"']*)", text):
            if match not in artifacts:
                artifacts.append(match)
    return procedure[:4], artifacts[:5]


def _investigation_findings(
    all_chats: list[dict[str, Any]],
    by_type: dict[str, list[str]],
) -> list[str]:
    findings: list[str] = []
    seen: set[str] = set()

    def add(item: str) -> None:
        item = item.strip()
        if len(item) < 15 or item in seen:
            return
        seen.add(item)
        findings.append(item[:350])

    for typ in ("decision", "constraint", "problem", "caveat"):
        for item in by_type.get(typ, [])[:4]:
            add(item)

    for chat in all_chats:
        if chat.get("status") != "archived":
            continue
        title = (chat.get("title") or f"Session {chat.get('id')}").strip()
        summary = (chat.get("content") or "").strip()
        if summary:
            add(f"{title}: {summary[:240]}")
        elif title:
            add(title)

    return findings[:8]


def _investigation_next_checks(
    by_type: dict[str, list[str]],
    all_chats: list[dict[str, Any]],
) -> list[str]:
    checks: list[str] = []
    seen: set[str] = set()

    for typ in ("active_work", "problem", "goal"):
        for item in by_type.get(typ, [])[:4]:
            if item not in seen:
                seen.add(item)
                checks.append(item[:350])

    for chat in all_chats:
        if chat.get("status") != "archived":
            continue
        title = (chat.get("title") or "").strip()
        if title and re.search(r"(?i)\b(check|verify|inspect|todo|next)\b", title):
            if title not in seen:
                seen.add(title)
                checks.append(title[:200])

    return checks[:6]


_ABANDONED_RE = re.compile(r"(?i)\b(abandoned|wiped|removed|no longer|deprecated|replaced with)\b")
_EXTERNAL_DEP_RE = re.compile(
    r"(?i)\b(oauth|oidc|saml|sso|google|azure|ldap|cloudflare access|tailscale serve)\b"
)


def _integration_external_deps(
    memories: list[dict[str, Any]],
    by_type: dict[str, list[str]],
) -> list[dict[str, str]]:
    deps: list[dict[str, str]] = []
    seen: set[str] = set()
    abandoned_topics: set[str] = set()

    for m in memories:
        content = (m.get("content") or "").strip()
        if _ABANDONED_RE.search(content):
            for match in _EXTERNAL_DEP_RE.findall(content):
                abandoned_topics.add(match.lower())

    for m in memories:
        content = (m.get("content") or "").strip()
        if not content or not _EXTERNAL_DEP_RE.search(content):
            continue
        topic = _EXTERNAL_DEP_RE.search(content)
        if not topic:
            continue
        key = topic.group(0).lower()
        if key in abandoned_topics or key in seen:
            continue
        seen.add(key)
        status = "active"
        if any(_ABANDONED_RE.search(o) for o in by_type.get("problem", []) if key in o.lower()):
            status = "stale"
        deps.append({"name": key, "notes": content[:200], "status": status})

    return deps[:6]


def _yaml_external_deps_block(deps: list[dict[str, str]]) -> list[str]:
    if not deps:
        return []
    lines = ["external_deps:"]
    for dep in deps[:6]:
        lines.append(f"  - name: {_yaml_quote(dep.get('name', 'unknown')[:80])}")
        if dep.get("notes"):
            lines.append(f"    notes: {_yaml_quote(dep['notes'][:200])}")
        if dep.get("status"):
            lines.append(f"    status: {dep['status']}")
    return lines


def _filter_cross_project_paths(paths: list[str], slug: str) -> list[str]:
    """Drop paths that belong to other compose.manager projects."""
    filtered: list[str] = []
    for p in paths:
        m = re.search(r"/compose\.manager/projects/([^/]+)", p)
        if m and m.group(1) != slug:
            continue
        filtered.append(p)
    return filtered


def write_spec_yaml(slug: str, content: str) -> str:
    path_dir = _projects_dir() / slug
    path_dir.mkdir(parents=True, exist_ok=True)
    path = path_dir / "SPEC.yaml"
    path.write_text(content, encoding="utf-8")
    return str(path)


def read_spec_yaml(slug: str) -> str:
    path = _projects_dir() / slug / "SPEC.yaml"
    if path.is_file():
        return path.read_text(encoding="utf-8", errors="replace")
    return ""


def spec_mtime(slug: str) -> str | None:
    path = _projects_dir() / slug / "SPEC.yaml"
    if not path.is_file():
        return None
    return datetime.utcfromtimestamp(path.stat().st_mtime).isoformat()


_META_MEMORY_RE = re.compile(
    r"(?i)\b(SPEC\.yaml|distill_spec|handoff_tier|env_required is|session #\d+ contained|"
    r"pipeline is built|Wolf Leader testing|IDE Storage testing|meta-junk|never made it into SPEC|"
    r"agent brief|distill_all|handoff robustness)\b"
)


# Conversational narration that should not surface as a durable "decision".
_NARRATION_PREFIX_RE = re.compile(r"(?i)^(so|then|now|also|but|and|ok|okay|well)\b[\s,]")
_NARRATION_BODY_RE = re.compile(
    r"(?i)\b(your messages|you were|were never|was never|wasn't|weren't|"
    r"not receiving|never actually|never reaching)\b"
)
# Filler preamble that carries no durable content ("…Summary:", "Here's where things stand").
_FILLER_RE = re.compile(
    r"(?i)(\bsummary\s*:?\s*$|here'?s where things stand|where things stand\s*:?\s*$|"
    r"here'?s the rundown|^here'?s )"
)


def _is_durable_decision(text: str) -> bool:
    """Drop conversational narration / filler; keep durable decisions."""
    t = (text or "").strip()
    if len(t) < 15 or t.endswith("?"):
        return False
    if _NARRATION_PREFIX_RE.match(t) or _NARRATION_BODY_RE.search(t):
        return False
    if _FILLER_RE.search(t):
        return False
    return True


def _memories_by_type(
    memories: list[dict],
    *,
    slug: str = "",
    project_name: str = "",
) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for m in memories:
        t = m.get("type") or "note"
        c = (m.get("content") or "").strip()
        if len(c) < 15 or _META_MEMORY_RE.search(c):
            continue
        if slug and not is_memory_relevant_to_project(c, slug, project_name):
            continue
        # decisions and constraints both surface as SPEC "decisions" — strip narration.
        if t in ("decision", "constraint") and not _is_durable_decision(c):
            continue
        out.setdefault(t, []).append(c[:350])
    return out


def _brief_from_spec(spec_yaml: str, project: dict, slug: str) -> str:
    """Compact markdown view for web UI."""
    name = project.get("name") or slug
    lines = [
        f"# Agent brief — {name}",
        "",
        "_Generated from SPEC.yaml — canonical checkpoint for agents._",
        "",
        "```yaml",
        spec_yaml.strip(),
        "```",
        "",
        "## Agent instructions",
        "",
        "1. Load SPEC.yaml fields first; archived chats are optional drill-down.",
        "2. Follow `continue_mode` — do not redeploy if mode is compose_maintain.",
        "3. Call `remember()` for new decisions; `/save` at session end.",
        "",
    ]
    return "\n".join(lines)


def distill_spec(project_id: int) -> dict[str, Any]:
    now = datetime.utcnow().isoformat()
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
        row = cur.fetchone()
        if not row:
            raise ValueError(f"Project {project_id} not found")
        project = dict(row)

        slug = project.get("slug") or f"project-{project_id}"
        mode = get_continue_mode(project)
        stored_deploy_state = get_deploy_state(project)

        cur.execute(
            """
            SELECT m.role, m.content FROM messages m
            JOIN chats c ON c.id = m.chat_id
            WHERE c.project_id = ? ORDER BY m.id DESC LIMIT 120
            """,
            (project_id,),
        )
        assistant_texts = [
            dict(r)["content"]
            for r in cur.fetchall()
            if dict(r).get("role") == "assistant" and dict(r).get("content")
        ]

        # Durable learnings (decision/constraint/caveat) come first regardless of
        # age, so the manual accumulates strong facts instead of churning on the
        # most recent debug chatter; recency breaks ties within a type.
        cur.execute(
            """
            SELECT type, content FROM memories
            WHERE project_id = ? AND COALESCE(status, 'active') = 'active'
            ORDER BY
              CASE type
                WHEN 'decision' THEN 0 WHEN 'constraint' THEN 1 WHEN 'caveat' THEN 2
                WHEN 'goal' THEN 3 WHEN 'active_work' THEN 4 ELSE 5
              END,
              updated_at DESC
            LIMIT 60
            """,
            (project_id,),
        )
        memories = [dict(r) for r in cur.fetchall()]

        cur.execute(
            """
            SELECT c.id, c.title, c.content, c.status, c.updated_at,
                   (SELECT COUNT(*) FROM messages m WHERE m.chat_id = c.id) AS message_count
            FROM chats c WHERE c.project_id = ?
            ORDER BY c.updated_at DESC
            """,
            (project_id,),
        )
        all_chats = [dict(r) for r in cur.fetchall()]
        message_counts = {c["id"]: c.get("message_count") or 0 for c in all_chats}

    project_name = project.get("name") or slug
    by_type = _memories_by_type(memories, slug=slug, project_name=project_name)
    paths = _filter_cross_project_paths(_extract_paths(assistant_texts), slug)[:10]
    compose = (project.get("compose_path") or "").strip()

    preflight = run_preflight(
        project,
        slug=slug,
        continue_mode=mode,
        assistant_texts=assistant_texts,
        discovered_paths=paths,
    )
    discovered = preflight.get("compose_path") or discover_compose_path(slug, project, paths)
    if discovered and (not compose or not os.path.isdir(compose)):
        compose = discovered
    public = __import__("os").environ.get("IDE_STORAGE_PUBLIC_URL", "http://127.0.0.1:6971").rstrip("/")
    brief_url = f"{public}/api/projects/{slug}/agent-brief"

    observed_deploy = preflight.get("observed_deploy_state") or stored_deploy_state
    if observed_deploy in ("deployed", "removed", "partial"):
        deploy_state = observed_deploy
    elif observed_deploy == "unknown":
        # Hub cannot observe its own stack from inside the container; preserve
        # documented live state instead of inheriting a stale "removed".
        if stored_deploy_state in ("deployed", "partial"):
            deploy_state = stored_deploy_state
        elif mode == "compose_maintain":
            deploy_state = "deployed"
        else:
            deploy_state = stored_deploy_state
    else:
        deploy_state = stored_deploy_state

    appdata_path = preflight.get("appdata_path")
    seed = _load_seed_sections(slug)
    seed_blob = seed[0] if seed else ""
    env_vars = extract_env_vars(
        assistant_texts + ([seed_blob] if seed_blob else []),
        slug=slug,
        appdata_path=appdata_path,
    )
    if compose and mode.startswith("compose"):
        from_compose_env = extract_env_from_compose(compose)
        if from_compose_env:
            env_vars = from_compose_env
    services = (
        merge_services(
            compose,
            assistant_texts,
            slug,
            seed_text=seed_blob,
            project=project,
            paths=paths,
        )
        if mode.startswith("compose")
        else []
    )
    config_files = extract_config_files(
        assistant_texts + ([seed_blob] if seed_blob else []),
        appdata_path,
        compose_path=compose or None,
    )

    rebuild_steps: list[str] = []
    effective_compose_for_rebuild = preflight.get("compose_path") or compose
    if preflight.get("compose") == "present" and effective_compose_for_rebuild:
        rebuild_steps.append(f"cd {effective_compose_for_rebuild} && docker compose up -d")
    if preflight.get("appdata") == "missing" and appdata_path:
        rebuild_steps.append(f"Create appdata at {appdata_path} (.env, config.yaml) — see drill_down")

    handoff_tier = compute_handoff_tier(
        mode,
        preflight,
        has_rebuild_steps=bool(rebuild_steps),
        has_services=bool(services),
    )
    thin_checkpoint = (
        not services
        and not by_type.get("decision")
        and not by_type.get("constraint")
        and handoff_tier == "continue"
    )
    force_drill = thin_checkpoint or (
        handoff_tier in ("orient", "continue")
        and _has_archived_install_chat(all_chats)
        and not by_type.get("decision")
    )
    drill = drill_down_for_project(
        all_chats,
        handoff_tier=handoff_tier,
        message_counts=message_counts,
        force_if_thin=force_drill,
        memories=memories,
    )
    pickup = pickup_for_tier(
        project.get("name") or slug,
        slug,
        handoff_tier=handoff_tier,
        continue_mode=mode,
        brief_url=brief_url,
        preflight=preflight,
    )

    lines = [
        f"name: {_yaml_quote(project.get('name') or slug)}",
        f"slug: {slug}",
        f"continue_mode: {mode}",
        f"deploy_state: {deploy_state}",
        f"observed_deploy_state: {observed_deploy}",
        f"handoff_tier: {handoff_tier}",
        f"updated: {now[:19]}Z",
        f"pickup: {_yaml_quote(pickup)}",
        f"brief_url: {_yaml_quote(brief_url)}",
    ]
    lines.extend(on_disk_yaml_lines(preflight))
    lines.extend(_yaml_drill_down(drill))

    effective_compose = preflight.get("compose_path") or compose
    if effective_compose and mode.startswith("compose"):
        # Skip baking a host path we could not verify (stale migration paths).
        if preflight.get("compose") != "unknown" or os.path.isdir(effective_compose):
            lines.append(f"compose: {_yaml_quote(effective_compose)}")
    ctx_path = _compose_context_path(effective_compose or "", slug) if mode.startswith("compose") else None
    if ctx_path:
        lines.append(f"compose_context: {_yaml_quote(ctx_path)}")
    lines.extend(_yaml_persistence_block(preflight))

    overview = project.get("description") or ""
    project_md = read_project_md(slug)
    if "## Overview" in project_md:
        m = re.search(r"## Overview\s*\n+(.*?)(?=\n## |\Z)", project_md, re.DOTALL)
        if m:
            overview = m.group(1).strip() or overview
    if overview:
        lines.append(f"overview: {_yaml_quote(overview[:300])}")

    # Mode-specific blocks
    if mode == "server_daemon":
        plugin = preflight.get("plugin_path") or compose or f"/boot/config/plugins/{slug}"
        lines.append(f"plugin_root: {_yaml_quote(plugin)}")
        decisions = by_type.get("decision", []) + by_type.get("constraint", [])
        lines.extend(_yaml_list("policy", decisions[:6]))
        lines.extend(_yaml_list("known_bugs", by_type.get("problem", [])[:4]))
        pattern = DAEMON_PROCESS_PATTERNS.get(slug, slug.replace("-", "_"))
        cmds = [f"pgrep -af {pattern}"]
        if plugin:
            ensure = os.path.join(plugin, "ensure_daemon.sh")
            if os.path.isfile(ensure):
                cmds.append(f"bash {ensure}")
        lines.extend(_yaml_list("commands", cmds[:4]))

    elif mode == "client_setup":
        server_paths = [p for p in paths if "ssh" in p or "authorized_keys" in p][:5]
        if not server_paths:
            server_paths = ["/boot/config/ssh/root/authorized_keys"]
        lines.extend(_yaml_list("server_paths", server_paths))
        lines.extend(_yaml_list("constraints", by_type.get("constraint", [])[:5]))
        client_proc, client_arts = _client_setup_steps(memories, assistant_texts)
        if client_proc:
            lines.extend(_yaml_list("client_procedure", client_proc))
        if client_arts:
            lines.extend(_yaml_list("client_artifacts", client_arts))
        elif by_type.get("note"):
            lines.extend(_yaml_list("client_procedure", by_type.get("note", [])[:3]))

    elif mode in ("compose_deploy", "compose_maintain"):
        lines.extend(_yaml_list("paths", paths[:8]))
        lines.extend(_yaml_env_block(env_vars))
        lines.extend(_yaml_services_block(services))
        if appdata_path and preflight.get("appdata") == "present":
            lines.append(f"appdata: {_yaml_quote(appdata_path)}")
        lines.extend(_yaml_config_files_block(config_files))
        lines.extend(
            _yaml_list(
                "decisions",
                (by_type.get("decision", []) + by_type.get("constraint", []))[:6],
            )
        )
        if handoff_tier in ("rebuild", "orient") and rebuild_steps:
            lines.extend(_yaml_list("rebuild", rebuild_steps))
        elif mode == "compose_deploy" and rebuild_steps:
            lines.extend(_yaml_list("rebuild", rebuild_steps))
        if mode == "compose_maintain":
            lines.extend(_yaml_list("fixes_applied", by_type.get("decision", [])[:4]))
            lines.extend(_yaml_list("known_issues", by_type.get("problem", [])[:4]))

    elif mode == "external_host":
        ext = ["external_service:"]
        if preflight.get("external_host"):
            ext.append(f"  host: {_yaml_quote(str(preflight['external_host']))}")
        if preflight.get("external_path"):
            ext.append(f"  path: {_yaml_quote(str(preflight['external_path']))}")
        if preflight.get("external_port"):
            ext.append(f"  port: {_yaml_quote(str(preflight['external_port']))}")
        if preflight.get("external_url"):
            ext.append(f"  url: {_yaml_quote(str(preflight['external_url']))}")
        if preflight.get("external_service"):
            ext.append(f"  service: {_yaml_quote(str(preflight['external_service']))}")
        if preflight.get("external_note"):
            ext.append(f"  note: {_yaml_quote(str(preflight['external_note'])[:300])}")
        lines.extend(ext)
        lines.extend(
            _yaml_list(
                "decisions",
                (by_type.get("decision", []) + by_type.get("constraint", []))[:6],
            )
        )
        lines.extend(_yaml_list("known_issues", by_type.get("problem", [])[:4]))
        lines.extend(_yaml_list("paths", paths[:6]))

    elif mode == "integration":
        lines.extend(_yaml_list("paths", paths[:8]))
        lines.extend(_yaml_external_deps_block(_integration_external_deps(memories, by_type)))
        active_blockers = [
            b for b in by_type.get("problem", [])[:4]
            if not _ABANDONED_RE.search(b)
        ]
        lines.extend(_yaml_list("decisions", by_type.get("decision", [])[:6]))
        lines.extend(_yaml_list("blockers", active_blockers))

    else:  # investigation
        lines.extend(_yaml_list("findings", _investigation_findings(all_chats, by_type)))
        lines.extend(_yaml_list("next_checks", _investigation_next_checks(by_type, all_chats)))

    if seed:
        lines.append(f"seed_doc: {_yaml_quote(seed[0][:500])}")

    spec = _truncate("\n".join(lines) + "\n", SPEC_MAX_CHARS)
    spec_path = write_spec_yaml(slug, spec)
    validation = validate_spec(spec, mode)
    brief_md = _brief_from_spec(spec, project, slug)
    brief_path = write_agent_brief(slug, _truncate(brief_md, 8000))

    # Persist observed deploy state; auto-set compose_path when discovered
    meta = metadata_patch(project, deploy_state=deploy_state)
    meta["observed_deploy_state"] = observed_deploy
    meta["handoff_tier"] = handoff_tier
    meta["preflight_at"] = now
    discovered_compose = preflight.get("compose_path") or effective_compose
    with db_conn() as conn:
        cur = conn.cursor()
        if discovered_compose and not (project.get("compose_path") or "").strip():
            cur.execute(
                "UPDATE projects SET compose_path = ?, updated_at = ? WHERE id = ?",
                (discovered_compose, now, project_id),
            )
        cur.execute(
            "UPDATE projects SET metadata = ?, updated_at = ? WHERE id = ?",
            (json.dumps(meta), now, project_id),
        )
        conn.commit()

    return {
        "project_id": project_id,
        "slug": slug,
        "continue_mode": mode,
        "deploy_state": deploy_state,
        "observed_deploy_state": observed_deploy,
        "handoff_tier": handoff_tier,
        "preflight": preflight,
        "drill_down": drill,
        "spec_path": spec_path,
        "spec_chars": len(spec),
        "brief_path": brief_path,
        "pickup": pickup,
        "updated_at": now,
        "spec_validation": validation,
    }


def distill_all_specs() -> list[dict[str, Any]]:
    results = []
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT id FROM projects WHERE COALESCE(status, 'active') != 'archived' ORDER BY id"
        )
        ids = [row[0] for row in cur.fetchall()]
    for pid in ids:
        try:
            results.append(distill_spec(pid))
        except Exception as exc:  # noqa: BLE001
            results.append({"project_id": pid, "error": str(exc)})
    return results
