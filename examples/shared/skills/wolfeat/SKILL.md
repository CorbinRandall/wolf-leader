---
name: wolfeat
description: Pick up a Wolf Leader project — pull its brief, recent howls, git state, memories, and open work — or connect a workspace that is not set up yet.
disable-model-invocation: true
---

# /wolfeat — recall and pick up

Use when the user says `/wolfeat`, “eat,” “catch me up,” “where did we leave off,” asks what another machine did, or wants to connect this workspace to Wolf Leader. This is the only deliberate recall command; it replaces the old `/new` setup path.

## Workflow

1. Resolve the Wolf Leader API URL from this client’s `wolf-leader.env` (`~/.codex`, `~/.cursor`, or `~/.claude`) or `WOLF_LEADER_API`.
2. Run the bundled script from this skill’s own `scripts` folder, from the project folder. It does the lookup without model tokens:

```bash
scripts/wolfeat.sh                           # project for this folder
scripts/wolfeat.sh SLUG                      # a named project
scripts/wolfeat.sh SLUG "question to search" # also run a hybrid search
```

3. Read the result by exit code:
   - `0` — summarize the hub’s `summary`, the current left-off point, the newest howl, and open work. Give the two or three facts that matter for what the user is about to do. Do not dump the whole brief.
   - `3` — no project is registered for this folder. Show the closest projects from the output and ask one short question: is this one of those, or a new project? Existing: re-run with its slug. New: say it will be created by `/wolfhowl` when there is work to save. Never create a project here.
   - `1` — the hub is unreachable or this workspace is not connected. Go to **Connect a workspace**.
4. Present write actions from `offers` (git pull, register path, read files, jobs) as a short question. Act only after the user agrees.

For more detail, fetch the live guide at `${API}/api/eat-guide`.

## Connect a workspace

Use at the start of a brand-new workspace, or when the script cannot reach the hub.

```bash
scripts/wolfeat.sh --setup
```

Follow every step in the returned onboarding `content`: MCP server, `AGENTS.md` in the workspace root, hooks, and the `/wolfhowl` and `/wolfeat` skills. Preserve existing client configuration. Then reload the client and re-run `scripts/wolfeat.sh`.

Report: hub reachable, MCP connected, `AGENTS.md` present, both skills installed, and which project this folder maps to (or that it is new).

## Missing files

If a configured Wolf Leader share holds project files that are missing locally, the sibling `wolfhowl/scripts/sync_share.py pull SLUG` helper copies only the missing files. It never overwrites or deletes local files.

On Windows, run the shell script through Git Bash. `/wolfeat` never writes to the hub except registering a path or starting a job the user asked for.
