"""Build agent-ready context references for stored chats."""
import json
import os
from typing import Any, Dict, Optional

from ide_storage.branding import MCP_SERVER_KEY, PRODUCT_NAME
from ide_storage.project_archetypes import host_label_suffix


def get_service_config() -> Dict[str, str]:
    port = os.environ.get("PORT", "6971")
    public_base = os.environ.get(
        "IDE_STORAGE_PUBLIC_URL",
        f"http://127.0.0.1:{port}",
    ).rstrip("/")
    compose_path = os.environ.get("IDE_STORAGE_COMPOSE_PATH", "/app")
    return {
        "container_name": os.environ.get(
            "IDE_STORAGE_CONTAINER", "wolf-leader"
        ),
        "compose_path": compose_path,
        "db_path_host": os.environ.get(
            "IDE_STORAGE_DB_PATH_HOST",
            os.path.join(compose_path, "data", "ide-work.db"),
        ),
        "db_path_container": os.environ.get(
            "IDE_STORAGE_DB_PATH", "/data/ide-work.db"
        ),
        "cursor_transcripts_root": os.environ.get(
            "CURSOR_TRANSCRIPTS_ROOT",
            "/root/.cursor/projects/root/agent-transcripts",
        ),
        "public_base_url": public_base,
        "local_base_url": os.environ.get(
            "IDE_STORAGE_LOCAL_URL", "http://127.0.0.1:6971"
        ).rstrip("/"),
        "mcp_url": os.environ.get(
            "IDE_STORAGE_MCP_URL", "http://127.0.0.1:6972/mcp"
        ),
        "onboarding_url": f"{public_base}/api/onboarding",
        "onboarding_web_url": f"{public_base}/?tab=setup",
        "onboarding_host_path": os.environ.get(
            "IDE_STORAGE_ONBOARDING_PATH",
            os.path.join(compose_path, "data", "ONBOARDING.md"),
        ),
        "port": port,
    }


def _parse_metadata(raw: Optional[str]) -> Dict[str, Any]:
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return {}


def build_agent_context(
    chat: Dict[str, Any],
    message_count: int = 0,
) -> Dict[str, Any]:
    cfg = get_service_config()
    chat_id = chat["id"]
    session_id = chat.get("session_id")
    metadata = _parse_metadata(chat.get("metadata"))

    api_chat_url = f"{cfg['public_base_url']}/api/chats/{chat_id}?include_messages=true"
    api_messages_url = f"{cfg['public_base_url']}/api/chats/{chat_id}/messages"
    api_context_url = f"{cfg['public_base_url']}/api/chats/{chat_id}/agent-context"
    web_url = f"{cfg['public_base_url']}/?chat={chat_id}"

    transcript_path = metadata.get("transcript_path")
    cursor_transcript = None
    if session_id:
        cursor_transcript = (
            f"{cfg['cursor_transcripts_root']}/{session_id}/{session_id}.jsonl"
        )

    return {
        "chat_id": chat_id,
        "project_id": chat.get("project_id"),
        "title": chat.get("title") or f"Chat #{chat_id}",
        "session_id": session_id,
        "workspace_path": chat.get("workspace_path"),
        "device_name": chat.get("device_name"),
        "created_at": chat.get("created_at"),
        "updated_at": chat.get("updated_at"),
        "message_count": message_count,
        "summary": chat.get("content"),
        "metadata": metadata,
        "service": cfg,
        "urls": {
            "web": web_url,
            "api_chat": api_chat_url,
            "api_messages": api_messages_url,
            "api_context": api_context_url,
            "api_list": f"{cfg['public_base_url']}/api/chats",
        },
        "paths": {
            "database_host": cfg["db_path_host"],
            "database_container": cfg["db_path_container"],
            "compose_folder": cfg["compose_path"],
            "cursor_transcript": cursor_transcript,
            "stored_transcript": transcript_path,
        },
    }


def format_agent_context_text(ctx: Dict[str, Any]) -> str:
    svc = ctx["service"]
    paths = ctx["paths"]
    urls = ctx["urls"]

    lines = [
        "## Prior chat context — load before continuing",
        "",
        f"**Title:** {ctx['title']}",
        f"**Chat ID:** {ctx['chat_id']}",
    ]

    if ctx.get("session_id"):
        lines.append(f"**Session ID:** {ctx['session_id']}")

    if ctx.get("workspace_path"):
        lines.append(f"**Workspace:** {ctx['workspace_path']}")

    lines.extend(
        [
            f"**Messages stored:** {ctx.get('message_count', 0)}",
            f"**Last updated:** {ctx.get('updated_at', 'unknown')}",
            "",
            f"### {PRODUCT_NAME} service",
            f"- **Container:** `{svc['container_name']}`",
            f"- **Compose folder:** `{svc['compose_path']}`",
            f"- **Database (host):** `{paths['database_host']}`",
            f"- **Database (container):** `{paths['database_container']}`",
            f"- **Web UI:** {urls['web']}",
            "",
            "### How to load full context",
            "1. Fetch the complete chat (recommended):",
            f"   ```",
            f"   curl -s '{urls['api_chat']}'",
            f"   ```",
            "2. Or fetch messages only:",
            f"   ```",
            f"   curl -s '{urls['api_messages']}'",
            f"   ```",
            "3. Or read from SQLite on the host:",
            f"   ```",
            f"   sqlite3 {paths['database_host']} "
            f"\"SELECT role, content FROM messages WHERE chat_id={ctx['chat_id']} ORDER BY id\"",
            f"   ```",
        ]
    )

    if paths.get("cursor_transcript"):
        lines.extend(
            [
                "",
                "### Cursor agent transcript (raw JSONL on server)",
                f"`{paths['cursor_transcript']}`",
            ]
        )

    if paths.get("stored_transcript"):
        lines.extend(
            [
                "",
                "### Stored transcript file (in container /data volume)",
                f"Container path: `{paths['stored_transcript']}`",
                f"Host path: `{svc['compose_path']}/data/{os.path.basename(paths['stored_transcript'])}`",
            ]
        )

    summary = (ctx.get("summary") or "").strip()
    if summary:
        lines.extend(["", "### Summary", summary])

    lines.extend(
        [
            "",
            "---",
            "Paste this block into a new agent chat so it knows exactly where to find prior context.",
        ]
    )

    if ctx.get("project_id"):
        lines.extend(
            [
                "",
                f"**Project ID:** {ctx['project_id']}",
                f"Load project context: `{svc['public_base_url']}/api/projects/{ctx['project_id']}/agent-context`",
            ]
        )

    return "\n".join(lines)


def build_project_agent_context(
    project: Dict[str, Any],
    chats: list,
    memories: list,
    project_md: str,
    *,
    archived_session_count: int = 0,
    archived_recent_sessions: Optional[list] = None,
    continue_mode: Optional[str] = None,
    preflight_compose_path: Optional[str] = None,
) -> Dict[str, Any]:
    cfg = get_service_config()
    pid = project["id"]
    slug = project.get("slug") or f"project-{pid}"
    mode = continue_mode or ""
    if mode == "server_daemon":
        compose = (
            project.get("compose_path")
            or f"/boot/config/plugins/{slug}"
            or ""
        )
    else:
        compose = preflight_compose_path or project.get("compose_path") or project.get("path") or ""

    return {
        "project_id": pid,
        "slug": slug,
        "name": project.get("name"),
        "status": project.get("status") or "active",
        "continue_mode": mode,
        "compose_path": compose,
        "description": project.get("description"),
        "project_md_path_host": f"{cfg['compose_path']}/data/projects/{slug}/PROJECT.md",
        "project_md_path_container": f"/data/projects/{slug}/PROJECT.md",
        "session_count": len(chats),
        "archived_session_count": archived_session_count,
        "archived_recent_sessions": archived_recent_sessions or [],
        "memory_count": len(memories),
        "sessions": [
            {
                "id": c["id"],
                "title": c.get("title") or f"Chat #{c['id']}",
                "updated_at": c.get("updated_at"),
                "web": f"{cfg['public_base_url']}/?chat={c['id']}",
            }
            for c in chats
        ],
        "memories": memories,
        "project_md": project_md,
        "service": cfg,
        "urls": {
            "web": f"{cfg['public_base_url']}/?project={pid}",
            "api_project": f"{cfg['public_base_url']}/api/projects/{pid}",
            "api_chats": f"{cfg['public_base_url']}/api/projects/{pid}/chats",
            "api_context": f"{cfg['public_base_url']}/api/projects/{pid}/agent-context",
            "agent_brief": f"{cfg['public_base_url']}/api/projects/{slug}/agent-brief",
            "agents_md": f"{cfg['compose_path']}/data/AGENTS.md",
            "index_md": f"{cfg['compose_path']}/data/INDEX.md",
        },
    }


def format_project_context_text(ctx: Dict[str, Any]) -> str:
    svc = ctx["service"]
    urls = ctx["urls"]
    lines = [
        "## Project context — load before continuing",
        "",
        f"**Project:** {ctx['name']} (`{ctx['slug']}`)",
        f"**Project ID:** {ctx['project_id']}",
        f"**Status:** {ctx.get('status', 'active')}",
    ]
    if ctx.get("compose_path"):
        lines.append(f"**Compose:** `{ctx['compose_path']}`")
    lines.extend(
        [
            "",
            f"### {PRODUCT_NAME}",
            f"- **Container:** `{svc['container_name']}`",
            f"- **Web UI:** {urls['web']}",
            f"- **PROJECT.md (host):** `{ctx['project_md_path_host']}`",
            f"- **AGENTS.md:** `{urls['agents_md']}`",
            "",
            "### Load order for a fresh agent",
            "1. Fetch agent brief (canonical):",
            f"   `{urls['agent_brief']}`",
            "2. Typed memories below supplement the brief",
            "",
        ]
    )

    if ctx.get("memories"):
        lines.append("### Typed memories")
        for m in ctx["memories"][:20]:
            lines.append(f"- **{m['type']}:** {m['content'][:300]}")
        lines.append("")

    md = (ctx.get("project_md") or "").strip()
    if md:
        lines.extend(["### PROJECT.md", "", md, ""])

    archived_n = ctx.get("archived_session_count") or 0
    if archived_n:
        lines.append(
            f"### Prior sessions ({archived_n} archived in hub — use Archive tab or get_session if verbatim context needed)"
        )
        for s in (ctx.get("archived_recent_sessions") or [])[:2]:
            base = urls["web"].split("?")[0]
            lines.append(f"- [#{s['id']}] {s.get('title') or 'Session'} — {base}?chat={s['id']}")
        lines.append("")

    lines.extend(
        [
            "---",
            "Project-first context. Prefer agent brief URL over raw chat history.",
        ]
    )
    return "\n".join(lines)


def build_agent_start_prompt(
    name: str,
    slug: str,
    compose_path: str = "",
    *,
    cfg: Optional[Dict[str, str]] = None,
    continue_mode: Optional[str] = None,
) -> str:
    """
    Reliable start prompt for Cursor agents over SSH or remote workspace.
    WebFetch cannot reach LAN IPs; MCP may be disconnected — document both paths.
    """
    svc = cfg or get_service_config()
    local = svc.get("local_base_url", "http://127.0.0.1:6971")
    brief_local = f"{local}/api/projects/{slug}/agent-brief"
    mode = continue_mode or ""
    on_host = host_label_suffix()
    lines = [
        f"Work on {name}{on_host}.",
        "",
        f'1. MCP {MCP_SERVER_KEY} → set_project({{ slug: "{slug}" }}) → get_brief() or recall()',
        f"2. If MCP unavailable: run `curl -s {brief_local}` in shell — do NOT use WebFetch (blocks private LAN IPs)",
    ]
    if mode == "server_daemon":
        plugin = compose_path or f"/boot/config/plugins/{slug}"
        lines.append(f"3. Follow the brief; plugin/daemon edits under: `{plugin}`")
    elif mode == "client_setup":
        lines.append("3. Follow the brief; configure THIS client device (SSH keys, Cursor, etc.)")
    elif mode.startswith("compose"):
        lines.append("3. Follow the brief; compose edits under the project path below")
        if compose_path:
            lines.append(f"Compose: `{compose_path}`")
    else:
        lines.append("3. Follow the brief and on_disk preflight before acting")
        if compose_path:
            lines.append(f"Workspace: `{compose_path}`")
    return "\n".join(lines)


def build_agent_start_prompt_short(name: str, slug: str, *, cfg: Optional[Dict[str, str]] = None) -> str:
    """One-liner for humans; agents should use build_agent_start_prompt for full steps."""
    svc = cfg or get_service_config()
    local = svc.get("local_base_url", "http://127.0.0.1:6971")
    on_host = host_label_suffix()
    return (
        f"Work on {name}{on_host}. "
        f"MCP get_brief/recall, or: curl -s {local}/api/projects/{slug}/agent-brief"
    )


def build_agent_brief_response(
    project: Dict[str, Any],
    chats: list,
    memories: list,
    project_md: str,
    brief_md: str,
    brief_updated_at: Optional[str] = None,
    ctx: Optional[Dict[str, Any]] = None,
    spec_yaml: str = "",
    continue_mode: Optional[str] = None,
    deploy_state: Optional[str] = None,
    pickup_prompt: Optional[str] = None,
    handoff_tier: Optional[str] = None,
    drill_down: Optional[Dict[str, Any]] = None,
    preflight: Optional[Dict[str, Any]] = None,
    purpose_summary: Optional[str] = None,
) -> Dict[str, Any]:
    """Full agent landing payload for GET /api/projects/{slug}/agent-brief."""
    if ctx is None:
        ctx = build_project_agent_context(project, chats, memories, project_md)
    pid = project["id"]
    slug = project.get("slug") or f"project-{pid}"
    name = project.get("name") or slug
    cfg = get_service_config()
    compose = ctx.get("compose_path") or project.get("compose_path") or ""
    brief_url = f"{cfg['public_base_url']}/api/projects/{slug}/agent-brief"
    brief_url_local = f"{cfg['local_base_url']}/api/projects/{slug}/agent-brief"

    mode = continue_mode or ""
    _local_brief = (
        "Load context via MCP get_brief/recall, or curl the local brief URL on the host. "
        "Do not use WebFetch for private LAN IPs. "
    )
    if mode == "server_daemon":
        instructions = (
            "You are continuing work on this Unraid plugin/daemon project. "
            + _local_brief
            + "Edit files under plugin_root — not Docker Compose. "
            "At session end, /save or save_session to checkpoint project knowledge."
        )
    elif mode == "client_setup":
        instructions = (
            "You are setting up a client device for this homelab project. "
            + _local_brief
            + "Focus on SSH keys and client-side configuration; server may already be ready. "
            "At session end, /save or save_session to checkpoint project knowledge."
        )
    elif mode == "compose_maintain":
        instructions = (
            "You are maintaining a running Docker Compose stack. "
            + _local_brief
            + "Fix and tune only — do not redeploy unless explicitly asked. "
            "Use the compose path for file edits. "
            "At session end, /save or save_session to checkpoint project knowledge."
        )
    else:
        instructions = (
            "You are continuing work on this homelab project. "
            + _local_brief
            + "Verify on_disk preflight before acting. "
            "At session end, /save or save_session to checkpoint project knowledge."
        )
        if mode.startswith("compose") and compose:
            instructions += f" Compose path: {compose}."

    agent_prompt = pickup_prompt or build_agent_start_prompt(
        name, slug, compose, cfg=cfg, continue_mode=mode
    )
    agent_prompt_short = build_agent_start_prompt_short(name, slug, cfg=cfg)

    paste_lines = [
        instructions,
        "",
        f"**Project:** {name} (`{slug}`)",
    ]
    if continue_mode:
        paste_lines.append(f"**Continue mode:** `{continue_mode}`")
    if deploy_state:
        paste_lines.append(f"**Deploy state:** `{deploy_state}`")
    if handoff_tier:
        paste_lines.append(f"**Handoff tier:** `{handoff_tier}`")
    if drill_down and (drill_down.get("required") or drill_down.get("optional")):
        req = ", ".join(drill_down.get("required") or [])
        opt = ", ".join(drill_down.get("optional") or [])
        if req:
            paste_lines.append(f"**Drill down (required):** {req}")
        if opt:
            paste_lines.append(f"**Drill down (optional):** {opt}")
    if preflight:
        kind = preflight.get("kind", "compose")
        if kind == "daemon":
            paste_lines.append(
                f"**On disk:** plugin_root={preflight.get('plugin_root')}, "
                f"daemon_running={preflight.get('daemon_running')}"
            )
            plugin = preflight.get("plugin_path") or compose
            if plugin:
                paste_lines.append(f"**Plugin root:** `{plugin}`")
        elif kind == "client_setup":
            paths = preflight.get("server_paths") or []
            status = ", ".join(f"{p.get('path')}={p.get('status')}" for p in paths[:3])
            if status:
                paste_lines.append(f"**On disk (server):** {status}")
        else:
            paste_lines.append(
                f"**On disk:** compose={preflight.get('compose')}, "
                f"appdata={preflight.get('appdata')}, "
                f"containers={preflight.get('containers') or []}"
            )
            eff_compose = preflight.get("compose_path") or ctx.get("compose_path")
            if eff_compose and mode.startswith("compose"):
                paste_lines.append(f"**Compose:** `{eff_compose}`")
    elif mode.startswith("compose") and ctx.get("compose_path"):
        paste_lines.append(f"**Compose:** `{ctx.get('compose_path')}`")
    paste_lines.extend(
        [
            f"**Brief URL (LAN):** {brief_url}",
            f"**Brief URL (local shell):** {brief_url_local}",
            "",
            "---",
            "",
        ]
    )
    if drill_down and drill_down.get("urls"):
        paste_lines.append("### Drill-down sessions")
        for ref, url in drill_down["urls"].items():
            paste_lines.append(f"- {ref}: {url}")
        paste_lines.append("")
    if spec_yaml:
        paste_lines.extend(["## SPEC.yaml (canonical checkpoint)", "", "```yaml", spec_yaml.strip(), "```", ""])
    else:
        paste_lines.append(brief_md or "_Brief not generated yet — run Refresh brief in the web UI._")

    if purpose_summary is None:
        from .purpose_summary import build_purpose_summary

        purpose_summary = build_purpose_summary(
            project,
            spec_yaml=spec_yaml,
            project_md=project_md,
            continue_mode=continue_mode,
            handoff_tier=handoff_tier,
            deploy_state=deploy_state,
            preflight=preflight,
            archived_recent_sessions=(ctx or {}).get("archived_recent_sessions"),
            active_sessions=chats,
        )

    canonical = {
        **ctx,
        "brief_md": brief_md,
        "spec_yaml": spec_yaml,
        "continue_mode": continue_mode,
        "deploy_state": deploy_state,
        "handoff_tier": handoff_tier,
        "purpose_summary": purpose_summary,
        "drill_down": drill_down or {"required": [], "optional": []},
        "preflight": preflight or {},
        "pickup_prompt": agent_prompt,
        "brief_updated_at": brief_updated_at,
        "instructions": instructions,
        "agent_prompt": agent_prompt,
        "agent_prompt_short": agent_prompt_short,
        "paste_text": "\n".join(paste_lines),
        "urls": {
            **ctx["urls"],
            "agent_brief": brief_url,
            "agent_brief_local": brief_url_local,
        },
    }
    canonical["canonical_handoff"] = True
    return canonical


def format_agent_brief_text(payload: Dict[str, Any]) -> str:
    return payload.get("paste_text") or payload.get("brief_md") or ""
