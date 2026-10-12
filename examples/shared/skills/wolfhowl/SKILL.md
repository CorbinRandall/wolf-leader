---
name: wolfhowl
description: Save or broadcast work to Wolf Leader — match it to an existing project or create one with confirmation, upload the transcript, and capture git and file context.
disable-model-invocation: true
---

# /wolfhowl — save and broadcast

Use when the user says `/wolfhowl`, “howl this,” “save this,” “checkpoint this chat,” “save to Wolf Leader,” or “make this a new Wolf Leader project.” This is the only deliberate save command; it replaces the old `/save` and `/new`.

## Keep it cheap

The bundled Python runner does the work: it reads this chat’s transcript from disk, matches the project, collects git state, and uploads. Memory extraction, embeddings, and the brief run on the hub. Do not retype or summarize the conversation yourself when the runner can read it.

If this client can hand a task to a lighter model or subagent (an economy or “fast” tier), run the steps below there and relay only the summary and the questions. Check the model policy recorded in the workspace `AGENTS.md`: on **economy** or **balanced**, delegate when possible; on **maximum quality**, stay on the current model. If no lighter agent exists, just run the runner directly — it is one command.

## Workflow

1. Run the runner from the project folder, using this skill’s own `scripts` folder:

```bash
scripts/wolfhowl.sh --session-id SESSION_ID
```

Pass this chat’s real session id. Never guess or use “the newest transcript.” If a slug is already known (from `resolve_project`, the workspace `AGENTS.md`, or the user), pass it first: `scripts/wolfhowl.sh SLUG --session-id SESSION_ID`.

2. Read the result by exit code:
   - `0` — saved. Go to step 4.
   - `3` — no confident project match (`needs_project_choice`). Go to step 3.
   - `2` — the runner needs something. If it says no local transcript was found, re-run with `--content` and a short typed-line summary (`decision: …`, `active_work: …`, `constraint: …`, one per line).
   - `1` — the save failed. Show the error. Do not report success.

3. Ask one short question: does this belong to an existing project, or is it a new project? Show the `candidates` the runner printed.
   - Existing: `scripts/wolfhowl.sh EXISTING-SLUG --session-id SESSION_ID`
   - New: propose a short name and slug from the conversation, confirm them, then
     `scripts/wolfhowl.sh NEW-SLUG --new --project-name "Name" --description "One line on what it is" --session-id SESSION_ID`

   Never create a project without the user choosing new.

4. Reply with the hub’s `summary` paragraph, then present the relevant `offers[]` as a short question. Do nothing from the offers until the user agrees.

## Git, when the user agrees

The howl records commit, branch, remote, and uncommitted-change count on its own. If the repo has no `origin`, the hub provides one on the share and the runner sets it (config only; nothing is pushed). To act on a `git_init`, `git_commit`, or `git_push` offer, run the git steps through the runner so the new commit is pinned to the howl without saving twice:

```bash
scripts/wolfhowl.sh --git-only --howl-id HOWL_ID --commit "what changed"
scripts/wolfhowl.sh --git-only --howl-id HOWL_ID --git-init --commit "wolf: initial" --push
```

If the user already asked to commit as part of the save, add `--commit "message"` (and `--push`) to the normal run instead. Never point a project at GitHub or another host unless the user asks.

## Other options

- `--cite PATH` (repeatable): files this chat attached or changed. Add `--ingest` only after the user agrees to index their contents.
- `--title "..."`: override the title taken from the first user message.
- `--no-share`, `--no-catalog`: skip the share mirror or file catalog.

On Windows, run the shell script through Git Bash. Without Python, the curl fallback can only save to a known existing slug; it cannot upload the transcript, match, or create a project. For more detail, fetch the live guide at `${API}/api/howl-guide`.

Never silently create a project. Never commit, push, ingest files, start jobs, delete, reset, or force-push without the user’s approval.
