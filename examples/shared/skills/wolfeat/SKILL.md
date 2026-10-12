---
name: wolfeat
description: Pull the latest Wolf Leader project context, recent howls, git state, related memories, and open work.
disable-model-invocation: true
---

# /wolfeat — answer the howl

Use this when the user says `/wolfeat`, “eat,” “catch me up,” or asks what another machine did.

## Run

1. Find the Wolf Leader API URL in this client’s `wolf-leader.env`. Check `~/.codex/wolf-leader.env`, then `~/.cursor/wolf-leader.env`, or use `WOLF_LEADER_API` from the environment.
2. Fetch and follow the live guide at `${WOLF_LEADER_API}/api/eat-guide`.
3. From the project folder, run the bundled script from this skill’s own `scripts` folder:

```bash
scripts/wolfeat.sh
scripts/wolfeat.sh SLUG
scripts/wolfeat.sh SLUG "question to search"
```

The agent should resolve the installed skill folder for its own IDE before running that command. On Windows, run the shell script through Git Bash.

4. Summarize the hub response with the current left-off point, newest howl, and open work. Present write actions from `offers` as a short question and only act after the user agrees.

If a configured Wolf Leader share contains project files missing locally, the sibling `wolfhowl/scripts/sync_share.py pull SLUG` helper can copy only missing files. It never overwrites or deletes local files.
