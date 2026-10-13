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

## The checklist

Every save returns `checklist`: the same questions answered in the same order, so nothing depends on you remembering.

1. **project** — which project this is, or that it was just created.
2. **saved** — conversation, memories, brief.
3. **repo** — does this project have files that should be under version control but are not?
4. **commit** — are there uncommitted changes?
5. **push** — has the hub's copy of the repo got them?
6. **offsite** — is there a recent copy of everything off the hub server?

Read the steps whose `state` is `ask` back to the user as short questions, in that order. Skip the `done` and `skip` ones. For a new project, step 3 is where a repo gets decided: if the folder holds code, Compose files, scripts or documents, offer one; if the project is only notes and decisions, it does not need one.

## Create a repo

When the user agrees to the `create_repo` offer, or asks to put a project under version control:

```bash
scripts/wolfhowl.sh SLUG --create-repo --plan   # show what would be committed and left out
scripts/wolfhowl.sh SLUG --create-repo          # git init, commit, push to the project's repo on the hub
```

Show the plan first. Secrets (`.env`, keys), databases, dependencies, nested repos and files over 25 MB are left out automatically; say so, and flag anything else that looks like a secret or data. Add `--no-push` to commit without pushing.

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
