---
name: save
description: Save or checkpoint the current Codex conversation to its existing Wolf Leader project. Use when the user says /save, $save, save this, save to Wolf Leader, or checkpoint this chat. Do not use to create a brand-new project.
---

# Save to Wolf Leader

Checkpoint the current Codex conversation to an existing Wolf Leader project.

1. Resolve the Wolf Leader API URL from the workspace `AGENTS.md` or the
   configured MCP server. Fetch and follow `/api/save-project-guide`; it is the
   live source of truth.
2. Resolve the current workspace to a project with Wolf Leader MCP. If path
   matching fails but the workspace instructions identify a project, select it
   explicitly. Do not create a new project from this skill.
3. Prefer MCP `save_session` with the current conversation, a concise title,
   its actual `occurred_at` time, and the resolved project.
4. If MCP is unavailable, use REST Path B from the live guide. Include `slug`,
   `title`, `content`, `occurred_at`, and the meaningful user/assistant
   `messages` available in context. Do not run Cursor transcript scripts;
   Codex transcripts do not use Cursor's storage layout.
5. Confirm the brief was refreshed and the session archived. Report the
   project name and slug, brief URL, archive status, and pickup summary.

If project detection is genuinely ambiguous, ask which existing project should
receive the checkpoint.
