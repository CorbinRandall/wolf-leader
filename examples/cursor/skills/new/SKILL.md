---
name: new
description: Start a brand-new Wolf Leader project — connect workspace, fetch onboarding, finish client setup.
disable-model-invocation: true
---

# New Wolf Leader project

Use at the **start** of a completely new project or zero-context agent session.

## Run when invoked

User says: "set up Wolf Leader", "new project", "connect to IDE Storage", or `/new`.

## Step 1 — Hub URL

Read `~/.cursor/wolf-leader.env` for `WOLF_LEADER_API` / `WOLF_LEADER_API_LOCAL`.

```bash
source ~/.cursor/wolf-leader.env 2>/dev/null || true
API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
```

## Step 2 — Fetch onboarding (mandatory)

**On shell** (WebFetch often blocks LAN IPs):

```bash
curl -s "${API}/api/onboarding"
```

Read the full `content` and execute every setup step that applies to this machine (MCP, AGENTS.md, hooks, skills, transcript import).

## Step 3 — User prompt (canonical)

Tell the agent:

```
Connect this workspace to Wolf Leader on corbox and finish setup.

Fetch and follow: ${API}/api/onboarding
```

(Substitute the real `API` value from step 1 — do not hardcode an IP.)

## Step 4 — If client files are missing

From a wolf-leader checkout:

```bash
WOLF_LEADER_API="${API}" WOLF_LEADER_MCP="${API%:6971}:6972/mcp" \
  ./scripts/install-cursor-client.sh
```

Reload the Cursor window after installing skills.

## Step 5 — Report

Confirm: MCP connected, `AGENTS.md` in workspace, `/save` skill present, onboarding checklist items done, hub reachable.
