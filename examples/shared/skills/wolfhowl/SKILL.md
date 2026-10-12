---
name: wolfhowl
description: Broadcast a session to Wolf Leader with its project, git state, file catalog, and follow-up offers.
disable-model-invocation: true
---

# /wolfhowl — broadcast to the pack

Use this when the user says `/wolfhowl`, “howl this,” or “broadcast this session.” It creates a richer checkpoint than `/save`: session summary, workspace path, git state, file catalog, and any configured share or vault updates.

## Run

1. Find the Wolf Leader API URL in this client’s `wolf-leader.env`. Check `~/.codex/wolf-leader.env`, then `~/.cursor/wolf-leader.env`, or use `WOLF_LEADER_API` from the environment.
2. Fetch and follow the live guide at `${WOLF_LEADER_API}/api/howl-guide`. The hub guide is the source of truth.
3. From the project folder, run the bundled script from this skill’s own `scripts` folder:

```bash
scripts/wolfhowl.sh SLUG --session-id SESSION_ID --content "active_work: concise current state"
```

The agent should resolve the installed skill folder for its own IDE before running that command. On Windows, run the shell script through Git Bash. Pin the project slug when it is known. Pass the real session ID. When the client transcript cannot be read locally, pass a typed summary with `--content`.

4. Return the hub’s `summary`, then present its `offers` as a short question. Only commit, push, ingest files, or start jobs after the user agrees.

The runner may mirror files to a configured Wolf Leader share. `--no-share` skips that step. Never push to a public git host unless the user asks.
