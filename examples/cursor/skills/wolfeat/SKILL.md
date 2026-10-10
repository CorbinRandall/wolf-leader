---
name: wolfeat
description: Pull the latest Wolf Leader context for this project onto this machine — brief, memories, howls with git SHAs, related notes, open jobs.
disable-model-invocation: true
---

# /wolfeat — answer the howl

Another machine howled; this one eats. Loads what the pack knows about the project you are in, then **offers** to `git pull`, register this machine's path, read file bodies already in RAG, or check/start connector jobs. Read-only unless the user says yes to an offer.

## Run when invoked

User says `/wolfeat`, "eat", "pull the latest context", "what did the other machine do", "catch me up".

## Do this

**Windows:** the scripts below are bash. Do NOT type `bash` in PowerShell (that is WSL and will fail). Run every command through Git Bash by full path:

```powershell
$env:CURSOR_WORKSPACE = (Get-Location).Path
& "C:\Program Files\Git\bin\bash.exe" -lc '~/.cursor/skills/wolfeat/scripts/wolfeat.sh'
```

Mac/Linux: run the bash lines as written.

1. Resolve the hub URL:

```bash
source ~/.cursor/wolf-leader.env 2>/dev/null || true
API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://wolf.local:6971}}"
```

2. **Fetch and follow the live guide**:

```bash
curl -s "${API}/api/eat-guide"
```

3. Run the bundled runner from the project folder:

```bash
~/.cursor/skills/wolfeat/scripts/wolfeat.sh                 # project from this folder
~/.cursor/skills/wolfeat/scripts/wolfeat.sh SLUG            # or by slug
~/.cursor/skills/wolfeat/scripts/wolfeat.sh SLUG "question" # also run a hybrid search
```

4. Reply with the hub's `summary` paragraph, then the two or three facts from `brief` that matter for what the user is about to do (`left_off`, newest `howls[0]`, any `open_jobs`). Do not paste the whole brief. Turn `offers[]` into one short question and act only on a yes.

## Files not in git

After `git pull`, offer: `python ~/.cursor/skills/wolfhowl/scripts/sync_share.py pull [slug]` from the project folder. It copies files that exist in the share mirror (`W:\wolf-leader\projects\<slug>\`, written by /wolfhowl) but are missing locally. It never overwrites or deletes.
