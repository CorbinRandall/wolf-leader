---
name: wolfhowl
description: Save or broadcast work to Wolf Leader — match it to an existing project or create one with confirmation, upload the transcript, and note the git commit it came from.
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

4. Reply with the hub’s `summary` paragraph. If `offers[]` has anything relevant, present it as a short question and do nothing until the user agrees.

## The checklist

Every save returns `checklist`: the same steps in the same order.

1. **project** — which project this is, or that it was just created.
2. **saved** — conversation, memories, brief.
3. **git** — if the folder is a git repo, the commit this save came from is noted.
4. **offsite** — whether there is a recent copy of the hub's notes and database off the server.

Only read a step back to the user when its `state` is `ask`.

## Git is recorded, not managed

Wolf Leader is a journal of how the work was done. It notes the commit a save came from and nothing more. Do not offer to create a repo, commit, or push as part of a save. If the user asks for those, do them the normal way with git.

One optional helper exists for someone who wants a project's folder versioned on the hub: `scripts/wolfhowl.sh SLUG --create-repo --plan` shows what would be committed and left out, and the same command without `--plan` runs `git init`, commits, and pushes to a repo on the hub. Use it only when the user asks for exactly that.

## Other options

- `--cite PATH` (repeatable): files this chat attached or changed. Add `--ingest` only after the user agrees to index their contents.
- `--attach PATH` (repeatable): keep an image or file with the project, such as screenshots or mockups. Pair each with `--attach-caption "..."` in the same order, and add `--attach-tag TAG` to label them all (for example `reddit-post`). They show under **Files & images** on the project page; agents list them with the `list_attachments` tool.
- `--title "..."`: override the title taken from the first user message.
- `--no-share`, `--no-catalog`: skip the share mirror or file catalog.

On Windows, run the shell script through Git Bash. Without Python, the curl fallback can only save to a known existing slug; it cannot upload the transcript, match, or create a project. For more detail, fetch the live guide at `${API}/api/howl-guide`.

Never silently create a project. Never commit, push, ingest files, start jobs, delete, reset, or force-push unless the user asks.
