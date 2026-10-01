const API = window.location.origin;

const DEFAULT_KANBAN_COLUMNS = [
  { status: "backlog", label: "Backlog", description: "Ideas and work waiting to start" },
  { status: "in_progress", label: "In progress", description: "Projects currently being worked on" },
  { status: "done", label: "Done for now", description: "Completed or paused indefinitely" },
];

let state = {
  tab: "kanban",
  kanbanColumns: DEFAULT_KANBAN_COLUMNS,
  chats: [],
  archivedChats: [],
  projects: [],
  activeChatId: null,
  activeProjectId: null,
  activeChat: null,
  activeProject: null,
  agentContextCache: {},
  agentBriefCache: null,
  leftOffCache: null,
  onboardingCache: null,
  searchResults: null,
  searchMode: "keyword",
  clientSetupCache: null,
  skills: [],
  skillsLibrary: null,
  activeSkillId: null,
};

const $ = (s) => document.querySelector(s);
const $$ = (s) => document.querySelectorAll(s);

function md(text) {
  if (!text) return "";
  try {
    return marked.parse(text, { breaks: true });
  } catch {
    return escapeHtml(text);
  }
}

function formatDate(iso) {
  if (!iso) return "—";
  const d = new Date(iso.endsWith("Z") ? iso : iso + "Z");
  if (Number.isNaN(d.getTime())) return (iso || "").slice(0, 16).replace("T", " ");
  return d.toLocaleString(undefined, { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" });
}

function escapeHtml(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function chatTitle(c) {
  return c.title || (c.content || "").slice(0, 60) || `Chat #${c.id}`;
}

function kanbanStatus(status) {
  if (state.kanbanColumns.some((column) => column.status === status)) return status;
  if (status === "done" || status === "archived") return state.kanbanColumns.find((column) => column.status === "done")?.status || state.kanbanColumns[0]?.status;
  if (status === "backlog") return state.kanbanColumns.find((column) => column.status === "backlog")?.status || state.kanbanColumns[0]?.status;
  return state.kanbanColumns.find((column) => column.status === "in_progress")?.status || state.kanbanColumns[0]?.status;
}

function kanbanStatusLabel(status) {
  return state.kanbanColumns.find((column) => column.status === kanbanStatus(status))?.label || "In progress";
}

function showToast(msg) {
  const el = $("#toast");
  el.textContent = msg;
  el.classList.remove("hidden");
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => el.classList.add("hidden"), 2500);
}

async function copyText(text, label) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const ta = document.createElement("textarea");
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand("copy");
    document.body.removeChild(ta);
  }
  showToast(`${label} copied`);
}

async function api(path, opts = {}) {
  const res = await fetch(`${API}${path}`, {
    headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
    ...opts,
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.detail || res.statusText);
  }
  if (res.status === 204) return null;
  const ct = res.headers.get("content-type") || "";
  return ct.includes("json") ? res.json() : res.text();
}

function setUrl(params) {
  const u = new URLSearchParams();
  if (params.chat) u.set("chat", params.chat);
  if (params.tab && params.tab !== "home") u.set("tab", params.tab);
  const path = params.projectSlug ? `/${encodeURIComponent(params.projectSlug)}` : "/";
  const qs = u.toString();
  history.replaceState(null, "", `${path}${qs ? `?${qs}` : ""}`);
}

function hideViews() {
  $("#empty-state").classList.add("hidden");
  $$(".view").forEach((v) => v.classList.add("hidden"));
}

// --- Navigation ---
function switchTab(tab) {
  state.tab = tab;
  document.body.dataset.tab = tab;
  state.searchResults = null;
  $("#search").value = "";
  $("#search").placeholder = searchPlaceholderForTab(tab);
  $("#duplicate-projects-btn").classList.toggle("hidden", !["projects", "kanban"].includes(tab));
  $$(".tab").forEach((t) => t.classList.toggle("active", t.dataset.tab === tab));
  renderSidebar();
  if (tab === "home") showHome();
  else if (tab === "setup") showSetup();
  else if (tab === "kanban") showKanban();
  else if (tab === "skills") showSkills();
  else if (tab === "projects") showClassicProjects();
}

async function runGlobalSearch(q) {
  const list = $("#sidebar-list");
  list.innerHTML = `<div class="loading">Searching…</div>`;
  try {
    const kinds = searchKindsForTab(state.tab);
    const url = `/api/search?q=${encodeURIComponent(q)}${kinds ? `&kinds=${kinds}` : ""}`;
    const data = await api(url);
    state.searchResults = data.results || [];
    state.searchMode = data.mode || "keyword";
    renderSidebar();
  } catch (err) {
    list.innerHTML = `<div class="loading">Search failed: ${escapeHtml(String(err))}</div>`;
  }
}

const KIND_ICON = { memory: "◈", project: "◫", chat: "▤", message: "◎" };

function renderSearchResults() {
  const list = $("#sidebar-list");
  const results = state.searchResults || [];
  const mode = state.searchMode || "keyword";
  const modeLabel = mode === "hybrid" ? "⊕ hybrid" : "keyword";
  if (!results.length) {
    list.innerHTML = `<div class="sidebar-hint">No results — try different words.</div>`;
    $("#list-count").textContent = `0 results · ${modeLabel}`;
    return;
  }
  list.innerHTML = results.map((r) => {
    const icon = KIND_ICON[r.kind] || "•";
    const title = escapeHtml(r.title || r.content || `#${r.id}`).slice(0, 72);
    const sim = r.similarity != null ? `${(r.similarity * 100).toFixed(0)}%` : "";
    const sub = escapeHtml(
      r.kind === "memory" ? (r.memory_type || "memory") :
      r.kind === "project" ? (r.slug || r.kind) :
      r.kind === "chat" ? "session" : r.kind
    );
    return `<button type="button" class="chat-item" data-sr-kind="${escapeHtml(r.kind)}" data-sr-id="${r.id}" data-sr-pid="${r.project_id || ""}" data-sr-cid="${r.chat_id || ""}">
      <div class="chat-item-title">${icon} ${title}</div>
      <div class="chat-item-meta"><span>${sub}</span>${sim ? `<span class="muted">${sim} match</span>` : ""}</div>
    </button>`;
  }).join("");
  list.querySelectorAll("[data-sr-kind]").forEach((b) => {
    b.addEventListener("click", async () => {
      const kind = b.dataset.srKind;
      const id = +b.dataset.srId;
      const pid = +b.dataset.srPid;
      if (kind === "project") {
        switchTab("projects");
        state.searchResults = null;
        $("#search").value = "";
        renderSidebar();
        await selectProject(id);
      } else if (kind === "chat") {
        switchTab("archive");
        state.searchResults = null;
        $("#search").value = "";
        renderSidebar();
        await selectChat(id);
      } else if (kind === "memory" && pid) {
        switchTab("projects");
        state.searchResults = null;
        $("#search").value = "";
        renderSidebar();
        await selectProject(pid);
      } else if (kind === "message" && b.dataset.srCid) {
        const chatId = +b.dataset.srCid;
        switchTab("archive");
        state.searchResults = null;
        $("#search").value = "";
        renderSidebar();
        await selectChat(chatId);
      }
    });
  });
  $("#list-count").textContent = `${results.length} results · ${modeLabel}`;
}

function renderSidebar() {
  const list = $("#sidebar-list");
  const q = ($("#search").value || "").toLowerCase().trim();

  if (state.searchResults !== null && state.searchResults !== undefined) {
    renderSearchResults();
    return;
  }

  if (state.tab === "home") {
    list.innerHTML = `<div class="sidebar-hint">Auto-generated index of projects and recent sessions.</div>`;
    $("#list-count").textContent = `${state.projects.length} projects`;
    return;
  }

  if (state.tab === "setup") {
    list.innerHTML = `<div class="sidebar-hint">Connect MCP, import chats, hooks, and merge steps for any device.</div>`;
    $("#list-count").textContent = "Onboarding";
    return;
  }

  if (state.tab === "kanban") {
    const q = ($("#search").value || "").toLowerCase().trim();
    const count = state.projects.filter((p) => !q || [p.name, p.slug, p.description, p.compose_path]
      .filter(Boolean).join(" ").toLowerCase().includes(q)).length;
    list.innerHTML = `<div class="sidebar-hint">Drag a project card to change its status. Select a card to open the full project.</div>`;
    $("#list-count").textContent = `${count} projects`;
    return;
  }

  if (state.tab === "skills") {
    const items = filteredSkills();
    list.innerHTML = items.length
      ? items.map((skill) => `
        <button type="button" class="chat-item${skill.id === state.activeSkillId ? " active" : ""}" data-sidebar-skill="${escapeHtml(skill.id)}">
          <div class="chat-item-title">${escapeHtml(skill.name)}</div>
          <div class="chat-item-meta"><span>${skill.file_count} files</span><span>${formatBytes(skill.size_bytes)}</span></div>
        </button>`).join("")
      : `<div class="loading">No skills found</div>`;
    list.querySelectorAll("[data-sidebar-skill]").forEach((button) =>
      button.addEventListener("click", () => selectSkill(button.dataset.sidebarSkill))
    );
    $("#list-count").textContent = `${items.length} skills`;
    return;
  }

  if (state.tab === "projects") {
    const items = state.projects.filter((p) => !q || [p.name, p.slug, p.compose_path].join(" ").toLowerCase().includes(q));
    list.innerHTML = items.length
      ? items.map((p) => `
        <button type="button" class="chat-item${p.id === state.activeProjectId ? " active" : ""}" data-project="${p.id}">
          <div class="chat-item-title">${escapeHtml(p.name)}</div>
          <div class="chat-item-meta"><span>${p.slug || ""}</span><span>${p.memory_count || 0} memories</span></div>
        </button>`).join("")
      : `<div class="loading">No projects</div>`;
    list.querySelectorAll("[data-project]").forEach((b) => b.addEventListener("click", () => selectProject(+b.dataset.project)));
    $("#list-count").textContent = `${items.length} projects`;
    return;
  }

  if (state.tab === "archive") {
    list.innerHTML = `<div class="sidebar-hint">Library — search all memories, sessions, and messages across every project.</div>`;
    const items = state.archivedChats.filter((c) => {
      if (!q) return true;
      return [c.title, c.content, c.project_name, String(c.id)].filter(Boolean).join(" ").toLowerCase().includes(q);
    });
    if (items.length) {
      list.innerHTML += items.map((c) => `
        <button type="button" class="chat-item${c.id === state.activeChatId ? " active" : ""}" data-chat="${c.id}">
          <div class="chat-item-title">${escapeHtml(chatTitle(c))}</div>
          <div class="chat-item-meta">
            <span>${formatDate(c.updated_at)}</span>
            ${c.project_name ? `<span>${escapeHtml(c.project_name)}</span>` : ""}
          </div>
        </button>`).join("");
      list.querySelectorAll("[data-chat]").forEach((b) => b.addEventListener("click", () => selectChat(+b.dataset.chat)));
    } else {
      list.innerHTML += `<div class="loading">No archived sessions</div>`;
    }
    $("#list-count").textContent = `${items.length} archived`;
    return;
  }

  const items = state.chats.filter((c) => {
    if (!q) return true;
    return [c.title, c.content, c.project_name, String(c.id)].filter(Boolean).join(" ").toLowerCase().includes(q);
  });
  list.innerHTML = items.length
    ? items.map((c) => `
      <button type="button" class="chat-item${c.id === state.activeChatId ? " active" : ""}" data-chat="${c.id}">
        <div class="chat-item-title">${escapeHtml(chatTitle(c))}</div>
        <div class="chat-item-meta">
          <span>${formatDate(c.updated_at)}</span>
          ${c.message_count != null ? `<span>${c.message_count} msgs</span>` : ""}
          ${c.project_name ? `<span>${escapeHtml(c.project_name)}</span>` : ""}
        </div>
      </button>`).join("")
    : `<div class="loading">No chats</div>`;
  list.querySelectorAll("[data-chat]").forEach((b) => b.addEventListener("click", () => selectChat(+b.dataset.chat)));
  $("#list-count").textContent = `${items.length} chats`;
}

async function loadData() {
  const [chats, archived, projects, kanban] = await Promise.all([
    api("/api/chats?limit=500"),
    api("/api/chats?limit=500&include_archived=true&status=archived"),
    api("/api/projects?limit=200"),
    api("/api/kanban/columns"),
  ]);
  state.chats = chats.chats || [];
  state.archivedChats = archived.chats || [];
  state.projects = projects.projects || [];
  state.kanbanColumns = kanban.columns || DEFAULT_KANBAN_COLUMNS;
  renderSidebar();
  if (state.tab === "kanban") renderKanban();
  if (state.tab === "projects") renderProjects();
}

function renderProjects() {
  const list = $("#projects-list");
  if (!list) return;
  const q = ($("#search").value || "").toLowerCase().trim();
  const projects = state.projects.filter((p) => !q || [p.name, p.description, p.slug].filter(Boolean).join(" ").toLowerCase().includes(q));
  list.innerHTML = projects.map((p) => `<button class="project-row" type="button" data-project-row="${p.id}"><span><strong>${escapeHtml(p.name)}</strong><small>${escapeHtml(p.description || "No description yet.")}</small></span><em>${escapeHtml(kanbanStatusLabel(p.status))}</em></button>`).join("") || `<p class="muted">No projects found.</p>`;
  $$('[data-project-row]').forEach((button) => button.addEventListener("click", () => selectProject(+button.dataset.projectRow)));
}

function showClassicProjects() {
  hideViews();
  if (state.activeProjectId) $("#project-view").classList.remove("hidden");
  else $("#empty-state").classList.remove("hidden");
  const project = state.projects.find((item) => item.id === state.activeProjectId);
  setUrl(project?.slug ? { projectSlug: project.slug } : { tab: "projects" });
}

function showProjects() { hideViews(); $("#projects-view").classList.remove("hidden"); renderProjects(); setUrl({ tab: "projects" }); }

// --- Home ---
async function showHome() {
  hideViews();
  $("#home-view").classList.remove("hidden");
  const data = await api("/api/index");
  $("#index-content").innerHTML = md(data.content);
  setUrl({ tab: "home" });
}

async function loadClientSetup() {
  if (!state.clientSetupCache) {
    state.clientSetupCache = await api("/api/client-setup");
    const desc = $("#client-setup-desc");
    if (desc && state.clientSetupCache.description) {
      desc.textContent = state.clientSetupCache.description;
    }
  }
  return state.clientSetupCache;
}

async function showSetup() {
  hideViews();
  $("#setup-view").classList.remove("hidden");
  if (!state.onboardingCache) {
    state.onboardingCache = await api("/api/onboarding");
  }
  await loadClientSetup();
  $("#setup-content").innerHTML = md(state.onboardingCache.content);
  setUrl({ tab: "setup" });
}

// --- Skills library ---
function formatBytes(bytes) {
  const value = Number(bytes) || 0;
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
}

function filteredSkills() {
  const q = ($("#search").value || "").toLowerCase().trim();
  return state.skills.filter((skill) => !q || [skill.name, skill.description, skill.id]
    .filter(Boolean).join(" ").toLowerCase().includes(q));
}

function skillInstructions(content) {
  return (content || "").replace(/^---\s*\r?\n[\s\S]*?\r?\n---\s*\r?\n/, "");
}

function renderSkills() {
  const grid = $("#skills-grid");
  if (!grid) return;
  const items = filteredSkills();
  grid.innerHTML = items.length
    ? items.map((skill) => `
      <article class="skill-card${skill.id === state.activeSkillId ? " active" : ""}">
        <button type="button" class="skill-card-open" data-skill="${escapeHtml(skill.id)}">
          <span class="skill-card-icon" aria-hidden="true">◇</span>
          <span class="skill-card-copy">
            <strong>${escapeHtml(skill.name)}</strong>
            <span>${escapeHtml(skill.description || "Portable agent workflow")}</span>
          </span>
          <span class="skill-card-meta">${skill.file_count} files · ${formatBytes(skill.size_bytes)}</span>
        </button>
      </article>`).join("")
    : `<div class="empty-library"><h3>No skills yet</h3><p>Sync user skills from a connected client to fill this library.</p></div>`;
  grid.querySelectorAll("[data-skill]").forEach((button) =>
    button.addEventListener("click", () => selectSkill(button.dataset.skill))
  );
}

async function showSkills() {
  hideViews();
  $("#skills-view").classList.remove("hidden");
  setUrl({ tab: "skills" });
  if (!state.skillsLibrary) {
    state.skillsLibrary = await api("/api/skills");
    state.skills = state.skillsLibrary.skills || [];
  }
  renderSidebar();
  renderSkills();
}

async function selectSkill(skillId) {
  state.activeSkillId = skillId;
  renderSidebar();
  renderSkills();
  const detail = await api(`/api/skills/${encodeURIComponent(skillId)}`);
  $("#skill-detail").classList.remove("hidden");
  $("#skill-detail-title").textContent = detail.name;
  $("#skill-detail-meta").textContent = `${detail.file_count} files · ${formatBytes(detail.size_bytes)} · ${detail.files.join(", ")}`;
  $("#skill-detail-content").innerHTML = md(skillInstructions(detail.content));
  $("#download-skill-btn").href = `/api/skills/${encodeURIComponent(skillId)}/download`;
  $("#skill-detail").scrollIntoView({ behavior: "smooth", block: "start" });
}

$("#copy-skills-install-btn").addEventListener("click", async () => {
  if (!state.skillsLibrary) state.skillsLibrary = await api("/api/skills");
  await copyText(state.skillsLibrary.install_prompt, "Skills install prompt");
});

$("#copy-skills-publish-btn").addEventListener("click", async () => {
  if (!state.skillsLibrary) state.skillsLibrary = await api("/api/skills");
  await copyText(state.skillsLibrary.publish_prompt, "Skills publish prompt");
});

// --- Duplicate projects ---
$("#duplicate-projects-btn").addEventListener("click", async () => {
  const data = await api("/api/projects/duplicates");
  if (!data.groups?.length) {
    showToast("No duplicate projects found");
    return;
  }
  const group = data.groups[0];
  const rows = group.projects.map((project) => `
    <option value="${project.id}">${escapeHtml(project.name)} · ${project.chat_count || 0} sessions · ${project.memory_count || 0} memories</option>`
  ).join("");
  const summary = group.projects.map((project) => `
    <div class="duplicate-project-row">
      <strong>${escapeHtml(project.name)}</strong>
      <span>Slug: ${escapeHtml(project.slug || "none")}</span>
      <span>Path: ${escapeHtml(project.path || "none")}</span>
      <span>Compose: ${escapeHtml(project.compose_path || "none")}</span>
      <span>${project.chat_count || 0} sessions · ${project.memory_count || 0} memories · ${project.snippet_count || 0} snippets</span>
    </div>`).join("");
  openModal("Merge duplicate projects", `
    <p class="modal-note">Found ${data.count} duplicate group${data.count === 1 ? "" : "s"}. Choose the record to keep. Linked sessions, memories, and snippets from the others will move into it.</p>
    <div class="duplicate-projects">${summary}</div>
    <label>Keep this project<select name="target_id">${rows}</select></label>
    <p class="modal-note">Original project files remain on disk for recovery. This removes only the extra project records after their linked data is moved.</p>
  `, async (form) => {
    const targetId = +form.target_id;
    const sourceIds = group.projects.map((project) => project.id).filter((id) => id !== targetId);
    const report = await api("/api/projects/merge", {
      method: "POST",
      body: JSON.stringify({ target_id: targetId, source_ids: sourceIds }),
    });
    await loadData();
    showToast(report.message);
  }, { saveLabel: "Merge projects" });
});

// --- Kanban ---
function projectMatchesKanbanSearch(project) {
  const q = ($("#search").value || "").toLowerCase().trim();
  if (!q) return true;
  return [project.name, project.slug, project.description, project.compose_path]
    .filter(Boolean).join(" ").toLowerCase().includes(q);
}

function renderKanbanCard(project) {
  const status = kanbanStatus(project.status);
  const options = state.kanbanColumns.map((column) =>
    `<option value="${escapeHtml(column.status)}"${column.status === status ? " selected" : ""}>${escapeHtml(column.label)}</option>`
  ).join("");
  return `
    <article class="kanban-card" draggable="true" data-kanban-project="${project.id}">
      <div class="kanban-card-topline">
        <h3><button type="button" class="kanban-card-open" data-kanban-open="${project.id}">${escapeHtml(project.name)}</button></h3>
        <span class="kanban-drag-handle" aria-hidden="true">⠿</span>
      </div>
      ${project.description ? `<p>${escapeHtml(project.description)}</p>` : ""}
      <div class="kanban-card-meta">
        <span>${project.memory_count || 0} memories</span>
        <span>${project.chat_count || 0} sessions</span>
      </div>
      <label class="kanban-status-control">
        <span class="sr-only">Move ${escapeHtml(project.name)}</span>
        <select data-kanban-select="${project.id}" aria-label="Status for ${escapeHtml(project.name)}">${options}</select>
      </label>
    </article>`;
}

function bindKanbanEvents() {
  $$("[data-kanban-project]").forEach((card) => {
    card.addEventListener("click", (event) => {
      if (event.target.closest("select")) return;
      selectProject(+card.dataset.kanbanProject);
    });
    card.addEventListener("dragstart", (event) => {
      card.classList.add("dragging");
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", card.dataset.kanbanProject);
    });
    card.addEventListener("dragend", () => {
      card.classList.remove("dragging");
      $$(".kanban-column").forEach((column) => column.classList.remove("drop-target"));
    });
  });

  $$('[data-column-drag-handle]').forEach((handle) => {
    let dragging = false;
    const sourceStatus = handle.dataset.columnDragHandle;
    const clearDrag = () => $$(".kanban-column").forEach((column) =>
      column.classList.remove("column-dragging", "column-drop-before", "column-drop-after")
    );
    handle.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      dragging = true;
      handle.setPointerCapture(event.pointerId);
      handle.closest(".kanban-column").classList.add("column-dragging");
    });
    handle.addEventListener("pointermove", (event) => {
      if (!dragging) return;
      const board = $("#kanban-board");
      const bounds = board.getBoundingClientRect();
      if (event.clientX > bounds.right - 35) board.scrollLeft += 15;
      if (event.clientX < bounds.left + 35) board.scrollLeft -= 15;
      clearDrag();
      handle.closest(".kanban-column").classList.add("column-dragging");
      const target = document.elementFromPoint(event.clientX, event.clientY)?.closest(".kanban-column");
      if (target && target.dataset.kanbanStatus !== sourceStatus) {
        const before = event.clientX < target.getBoundingClientRect().left + target.offsetWidth / 2;
        target.classList.add(before ? "column-drop-before" : "column-drop-after");
      }
    });
    handle.addEventListener("pointerup", (event) => {
      if (!dragging) return;
      dragging = false;
      const target = document.elementFromPoint(event.clientX, event.clientY)?.closest(".kanban-column");
      clearDrag();
      if (target && target.dataset.kanbanStatus !== sourceStatus) {
        const before = event.clientX < target.getBoundingClientRect().left + target.offsetWidth / 2;
        reorderKanbanColumn(sourceStatus, target.dataset.kanbanStatus, before);
      }
    });
    handle.addEventListener("pointercancel", () => { dragging = false; clearDrag(); });
    handle.addEventListener("keydown", (event) => {
      if (!["ArrowLeft", "ArrowRight"].includes(event.key)) return;
      event.preventDefault();
      const index = state.kanbanColumns.findIndex((column) => column.status === sourceStatus);
      const neighbor = state.kanbanColumns[index + (event.key === "ArrowLeft" ? -1 : 1)];
      if (neighbor) reorderKanbanColumn(sourceStatus, neighbor.status, event.key === "ArrowLeft");
    });
  });

  $$("[data-kanban-status]").forEach((column) => {
    column.addEventListener("dragover", (event) => {
      event.preventDefault();
      event.dataTransfer.dropEffect = "move";
      column.classList.add("drop-target");
    });
    column.addEventListener("dragleave", (event) => {
      if (!column.contains(event.relatedTarget)) column.classList.remove("drop-target", "column-drop-target");
    });
    column.addEventListener("drop", async (event) => {
      event.preventDefault();
      column.classList.remove("drop-target", "column-drop-target");
      const projectId = Number(event.dataTransfer.getData("text/plain"));
      if (projectId) await moveProject(projectId, column.dataset.kanbanStatus);
    });
  });

  $$('[data-kanban-select]').forEach((select) => {
    select.addEventListener("click", (event) => event.stopPropagation());
    select.addEventListener("change", async () => moveProject(+select.dataset.kanbanSelect, select.value));
  });
}

async function reorderKanbanColumn(sourceStatus, targetStatus, before = true) {
  if (!sourceStatus || sourceStatus === targetStatus) return;
  const previous = [...state.kanbanColumns];
  const moving = previous.find((column) => column.status === sourceStatus);
  if (!moving) return;
  const ordered = previous.filter((column) => column.status !== sourceStatus);
  const targetIndex = ordered.findIndex((column) => column.status === targetStatus);
  if (targetIndex < 0) return;
  ordered.splice(targetIndex + (before ? 0 : 1), 0, moving);
  const scrollLeft = $("#kanban-board").scrollLeft;
  state.kanbanColumns = ordered;
  renderKanban();
  $("#kanban-board").scrollLeft = scrollLeft;
  try {
    const data = await api("/api/kanban/columns-order", { method: "PUT", body: JSON.stringify({ statuses: ordered.map((column) => column.status) }) });
    state.kanbanColumns = data.columns;
    showToast("Column order saved");
  } catch (error) {
    state.kanbanColumns = previous; renderKanban(); showToast(`Could not reorder columns: ${error.message}`);
  }
}

function beginInlineColumnRename(status) {
  const title = document.querySelector(`[data-column-title="${CSS.escape(status)}"]`);
  const column = state.kanbanColumns.find((item) => item.status === status);
  if (!title || !column) return;
  const input = document.createElement("input");
  input.className = "kanban-title-input";
  input.value = column.label;
  title.replaceWith(input);
  input.focus(); input.select();
  let finished = false;
  const finish = async (save) => {
    if (finished) return; finished = true;
    const label = input.value.trim();
    if (!save || !label || label === column.label) return renderKanban();
    try {
      const data = await api(`/api/kanban/columns/${status}`, { method: "PUT", body: JSON.stringify({ label }) });
      state.kanbanColumns = data.columns; renderKanban(); showToast("Column renamed");
    } catch (error) { renderKanban(); showToast(`Could not rename column: ${error.message}`); }
  };
  input.addEventListener("keydown", (event) => { if (event.key === "Enter") finish(true); if (event.key === "Escape") finish(false); });
  input.addEventListener("blur", () => finish(true));
}

function renderKanban() {
  const board = $("#kanban-board");
  if (!board) return;
  const projects = state.projects.filter(projectMatchesKanbanSearch);
  board.innerHTML = state.kanbanColumns.map((column) => {
    const items = projects.filter((project) => kanbanStatus(project.status) === column.status);
    return `
      <section class="kanban-column" data-kanban-status="${column.status}" aria-labelledby="kanban-${column.status}">
        <header class="kanban-column-header">
          <div>
            <div class="kanban-title-line"><button type="button" class="column-drag-handle" data-column-drag-handle="${column.status}" aria-label="Drag ${escapeHtml(column.label)} column" title="Drag to reorder, or use left/right arrow keys"><span></span><span></span></button><h3 id="kanban-${column.status}"><button type="button" class="kanban-column-title" data-column-title="${column.status}" title="Double-click to rename">${escapeHtml(column.label)}</button></h3></div>
            <p>${escapeHtml(column.description || "")}</p>
          </div>
          <div class="kanban-column-actions"><span class="kanban-count" aria-label="${items.length} projects">${items.length}</span><button type="button" class="btn-link danger-link" data-delete-column="${column.status}">Delete</button></div>
        </header>
        <div class="kanban-card-list">
          ${items.length ? items.map(renderKanbanCard).join("") : `<p class="kanban-empty">Drop a project here</p>`}
        </div>
      </section>`;
  }).join("");
  bindKanbanEvents();
  $$('[data-column-title]').forEach((button) => button.addEventListener("dblclick", () => beginInlineColumnRename(button.dataset.columnTitle)));
  $$('[data-delete-column]').forEach((button) => button.addEventListener("click", async () => {
    const column = state.kanbanColumns.find((item) => item.status === button.dataset.deleteColumn);
    if (state.kanbanColumns.length === 1) return showToast("Keep at least one column");
    const section = button.closest(".kanban-column");
    if (section.querySelector(".kanban-delete-confirm")) return;
    const form = document.createElement("form");
    form.className = "kanban-delete-confirm";
    form.innerHTML = `<p>Delete ${escapeHtml(column.label)}? Projects will be kept.</p>
      <label>Move projects to<select name="move_to">${state.kanbanColumns.filter((item) => item.status !== column.status).map((item) => `<option value="${escapeHtml(item.status)}">${escapeHtml(item.label)}</option>`).join("")}</select></label>
      <div class="kanban-delete-actions"><button type="button" class="btn btn-secondary">Cancel</button><button type="submit" class="btn btn-danger">Delete column</button></div>
      <p role="alert"></p>`;
    section.querySelector(".kanban-column-header").after(form);
    form.querySelector('[type="button"]').addEventListener("click", () => { form.remove(); button.focus(); });
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const submit = form.querySelector('[type="submit"]');
      submit.disabled = true;
      try {
        const moveTo = form.elements.move_to.value;
        const data = await api(`/api/kanban/columns/${column.status}?move_to=${encodeURIComponent(moveTo)}`, { method: "DELETE" });
        state.kanbanColumns = data.columns;
        await loadData();
        showToast("Column deleted; projects kept");
      } catch (error) {
        form.querySelector('[role="alert"]').textContent = `Could not delete column: ${error.message}`;
        submit.disabled = false;
      }
    });
    form.querySelector("select").focus();
  }));
}

function showKanban() {
  hideViews();
  $("#kanban-view").classList.remove("hidden");
  renderKanban();
  setUrl({ tab: "kanban" });
}

async function moveProject(projectId, status) {
  const project = state.projects.find((item) => item.id === projectId);
  if (!project || kanbanStatus(project.status) === status) return;
  const previousStatus = project.status;
  project.status = status;
  renderKanban();
  renderSidebar();
  try {
    await api(`/api/projects/${projectId}`, { method: "PUT", body: JSON.stringify({ status }) });
    showToast(`${project.name} moved to ${kanbanStatusLabel(status)}`);
  } catch (error) {
    project.status = previousStatus;
    renderKanban();
    renderSidebar();
    showToast(`Could not move ${project.name}: ${error.message}`);
  }
}

// --- Project ---
async function selectProject(id) {
  state.activeProjectId = id;
  state.activeChatId = null;
  renderSidebar();
  hideViews();
  $("#project-view").classList.remove("hidden");
  const selectedProject = state.projects.find((item) => item.id === id);
  setUrl(selectedProject?.slug ? { projectSlug: selectedProject.slug } : { tab: "projects" });
  switchTab("projects");

  const [project, ctx, mdData, memories, chatsData] = await Promise.all([
    api(`/api/projects/${id}`),
    api(`/api/projects/${id}/agent-context`),
    api(`/api/projects/${id}/context`),
    api(`/api/memories?project_id=${id}`),
    api(`/api/projects/${id}/chats?archived=true`).catch(() => ({ archived: [] })),
  ]);
  const briefData = await api(`/api/projects/${project.slug || id}/agent-brief`).catch(() => null);

  state.activeProject = project;
  state.agentContextCache[`p${id}`] = ctx;
  state.agentBriefCache = briefData;

  $("#project-title").textContent = project.name;
  $("#project-meta").innerHTML = [
    project.slug && `Slug: ${project.slug}`,
    briefData?.continue_mode && `Mode: ${briefData.continue_mode}`,
    briefData?.deploy_state && `Deploy: ${briefData.deploy_state}`,
    project.compose_path && `Compose: ${project.compose_path}`,
    `Status: ${project.status || "active"}`,
  ].filter(Boolean).map((x) => `<span>${escapeHtml(x)}</span>`).join("");

  const purposeEl = $("#project-purpose");
  const overviewPanel = $("#project-overview-panel");
  const purpose = briefData?.purpose_summary || project.description || "";
  if (purpose) {
    purposeEl.textContent = purpose;
    purposeEl.classList.remove("hidden");
    overviewPanel?.classList.remove("hidden");
  } else {
    purposeEl.textContent = "";
    purposeEl.classList.add("hidden");
    overviewPanel?.classList.add("hidden");
  }

  await loadLeftOff(id, briefData?.where_we_left_off || null);

  if (briefData) {
    $("#brief-meta").textContent = [
      briefData.brief_updated_at && `Brief updated: ${formatDate(briefData.brief_updated_at)}`,
      briefData.spec_yaml && `${briefData.spec_yaml.length} char SPEC`,
      briefData.archived_session_count != null && `${briefData.archived_session_count} archived sessions`,
      briefData.memory_count != null && `${briefData.memory_count} memories`,
    ].filter(Boolean).join(" · ");
    const preview = briefData.brief_md || (briefData.spec_yaml
      ? `## Technical project state\n\n\`\`\`yaml\n${briefData.spec_yaml}\n\`\`\``
      : "");
    $("#agent-brief-preview").innerHTML = md(preview);
  } else {
    $("#brief-meta").textContent = "No brief yet — click Refresh brief.";
    $("#agent-brief-preview").innerHTML = `<p class="muted">Run distill to generate AGENT_BRIEF.md.</p>`;
  }

  $("#project-md").value = mdData.content || "";
  $("#project-md-preview").innerHTML = md(mdData.content);

  const memoryRows = memories.memories || [];
  const memoryLabels = { decision: "Decisions", constraint: "Constraints", active_work: "Active work", problem: "Problems", goal: "Goals", caveat: "Caveats", note: "Notes" };
  const grouped = Object.groupBy ? Object.groupBy(memoryRows, (m) => m.type || "note") : memoryRows.reduce((a,m) => ((a[m.type || "note"] ||= []).push(m),a),{});
  $("#memories-list").innerHTML = memoryRows.length
    ? Object.entries(grouped).map(([type, rows]) => `<section class="memory-group"><h4>${escapeHtml(memoryLabels[type] || type)}</h4>${rows.map((m) => `
      <div class="memory-item" data-mid="${m.id}">
        <span class="memory-body">${escapeHtml(m.content)}</span>
        <button type="button" class="btn-icon del-memory" data-mid="${m.id}" title="Delete">×</button>
      </div>`).join("")}</section>`).join("")
    : `<p class="muted">No saved knowledge yet.</p>`;

  $$(".del-memory").forEach((b) => b.addEventListener("click", async () => {
    if (!confirm("Delete this memory?")) return;
    await api(`/api/memories/${b.dataset.mid}`, { method: "DELETE" });
    selectProject(id);
  }));

  const chatList = chatsData.archived || [];
  const archivedN = chatsData.archived_count ?? chatList.length;
  $("#archived-count-label").textContent = archivedN ? `(${archivedN})` : "";
  $("#project-chats-list").classList.add("hidden");
  $("#project-chats-list").innerHTML = chatList.length
    ? chatList.map((c) => `
      <button type="button" class="link-item" data-goto-chat="${c.id}">${escapeHtml(chatTitle(c))} — ${formatDate(c.updated_at)}</button>`).join("")
    : `<p class="muted">No archived sessions yet. Use /save to checkpoint project knowledge.</p>`;

  $$("[data-goto-chat]").forEach((b) => b.addEventListener("click", () => {
    switchTab("archive");
    selectChat(+b.dataset.gotoChat);
  }));
}

// --- Chat ---
async function selectChat(id) {
  state.activeChatId = id;
  state.activeProjectId = null;
  renderSidebar();
  hideViews();
  $("#chat-view").classList.remove("hidden");
  setUrl({ chat: id, tab: "archive" });

  const [chat, ctx] = await Promise.all([
    api(`/api/chats/${id}?include_messages=true`),
    api(`/api/chats/${id}/agent-context`),
  ]);

  state.activeChat = chat;
  state.agentContextCache[id] = ctx;

  $("#chat-title").textContent = chatTitle(chat);
  $("#chat-meta").innerHTML = [
    chat.project_name && `Project: ${chat.project_name}`,
    chat.workspace_path && `Workspace: ${chat.workspace_path}`,
    chat.session_id && `Session: ${chat.session_id}`,
    `Updated: ${formatDate(chat.updated_at)}`,
  ].filter(Boolean).map((x) => `<span>${escapeHtml(x)}</span>`).join("");

  const summary = (chat.content || "").trim();
  if (summary) {
    $("#summary-section").classList.remove("hidden");
    $("#chat-summary").innerHTML = md(summary);
  } else {
    $("#summary-section").classList.add("hidden");
  }

  const messages = chat.messages || [];
  $("#message-count").textContent = messages.length;

  $("#messages").innerHTML = messages.length
    ? messages.map((m) => `
      <article class="message ${m.role}" data-mid="${m.id}">
        <div class="message-header">
          <span class="message-role">${escapeHtml(m.role)}</span>
          <div class="message-actions">
            <button type="button" class="btn-icon edit-msg" data-mid="${m.id}" title="Edit">✎</button>
            <button type="button" class="btn-icon del-msg" data-mid="${m.id}" title="Delete">×</button>
            <span class="message-time">${formatDate(m.created_at)}</span>
          </div>
        </div>
        <div class="message-body">${escapeHtml(m.content)}</div>
      </article>`).join("")
    : `<div class="loading">No messages stored.</div>`;

  $$(".edit-msg").forEach((b) => b.addEventListener("click", () => editMessage(+b.dataset.mid, messages)));
  $$(".del-msg").forEach((b) => b.addEventListener("click", async () => {
    if (!confirm("Delete this message?")) return;
    await api(`/api/messages/${b.dataset.mid}`, { method: "DELETE" });
    selectChat(id);
  }));
}

// --- Modals ---
const modal = $("#modal");

function openModal(title, fields, onSave, options = {}) {
  $("#modal-title").textContent = title;
  $("#modal-body").innerHTML = fields;
  $("#modal-form button[type=submit]").textContent = options.saveLabel || "Save";
  modal.showModal();
  $("#modal-form").onsubmit = async (e) => {
    e.preventDefault();
    const submitButton = $("#modal-form button[type=submit]");
    submitButton.disabled = true;
    const data = {};
    $("#modal-body").querySelectorAll("[name]").forEach((el) => {
      data[el.name] = el.value;
    });
    try {
      await onSave(data);
      modal.close();
    } finally {
      submitButton.disabled = false;
    }
  };
}

$("#modal-cancel").addEventListener("click", () => modal.close());

$("#edit-chat-btn").addEventListener("click", () => {
  const c = state.activeChat;
  if (!c) return;
  const projectOpts = state.projects.map((p) => `<option value="${p.id}"${p.id === c.project_id ? " selected" : ""}>${escapeHtml(p.name)}</option>`).join("");
  openModal("Edit chat", `
    <label>Title<input name="title" value="${escapeHtml(c.title || "")}" /></label>
    <label>Summary<textarea name="content" rows="8">${escapeHtml(c.content || "")}</textarea></label>
    <label>Project<select name="project_id"><option value="">—</option>${projectOpts}</select></label>
    <label>Status<select name="status"><option value="active"${c.status !== "archived" ? " selected" : ""}>active</option><option value="archived"${c.status === "archived" ? " selected" : ""}>archived</option></select></label>
  `, async (data) => {
    await api(`/api/chats/${c.id}`, {
      method: "PUT",
      body: JSON.stringify({
        title: data.title,
        content: data.content,
        project_id: data.project_id ? +data.project_id : null,
        status: data.status,
      }),
    });
    await loadData();
    selectChat(c.id);
    showToast("Chat saved");
  });
});

$("#delete-chat-btn").addEventListener("click", async () => {
  if (!state.activeChatId || !confirm("Delete this chat and all messages?")) return;
  await api(`/api/chats/${state.activeChatId}`, { method: "DELETE" });
  state.activeChatId = null;
  await loadData();
  hideViews();
  $("#empty-state").classList.remove("hidden");
  setUrl({ tab: "chats" });
  showToast("Chat deleted");
});

function editMessage(mid, messages) {
  const m = messages.find((x) => x.id === mid);
  if (!m) return;
  openModal("Edit message", `
    <label>Role<select name="role"><option value="user"${m.role === "user" ? " selected" : ""}>user</option><option value="assistant"${m.role === "assistant" ? " selected" : ""}>assistant</option></select></label>
    <label>Content<textarea name="content" rows="12">${escapeHtml(m.content)}</textarea></label>
  `, async (data) => {
    await api(`/api/messages/${mid}`, { method: "PUT", body: JSON.stringify(data) });
    selectChat(state.activeChatId);
    showToast("Message saved");
  });
}

$("#edit-project-btn").addEventListener("click", () => {
  const p = state.activeProject;
  if (!p) return;
  openModal("Edit project", `
    <label>Name<input name="name" value="${escapeHtml(p.name || "")}" /></label>
    <label>Slug<input name="slug" value="${escapeHtml(p.slug || "")}" /></label>
    <label>Compose path<input name="compose_path" value="${escapeHtml(p.compose_path || "")}" /></label>
    <label>Path<input name="path" value="${escapeHtml(p.path || "")}" /></label>
    <label>Description<textarea name="description" rows="4">${escapeHtml(p.description || "")}</textarea></label>
    <label>Status<select name="status">
      <option value="backlog"${kanbanStatus(p.status) === "backlog" ? " selected" : ""}>Backlog</option>
      <option value="in_progress"${kanbanStatus(p.status) === "in_progress" ? " selected" : ""}>In progress</option>
      <option value="done"${kanbanStatus(p.status) === "done" ? " selected" : ""}>Done for now</option>
    </select></label>
  `, async (data) => {
    await api(`/api/projects/${p.id}`, { method: "PUT", body: JSON.stringify(data) });
    await loadData();
    selectProject(p.id);
    showToast("Project saved");
  });
});

$("#delete-project-btn").addEventListener("click", async () => {
  if (!state.activeProjectId || !confirm("Delete this project? Chats will be unlinked, not deleted.")) return;
  await api(`/api/projects/${state.activeProjectId}`, { method: "DELETE" });
  state.activeProjectId = null;
  await loadData();
  showHome();
  showToast("Project deleted");
});

$("#add-memory-btn").addEventListener("click", () => {
  const pid = state.activeProjectId;
  if (!pid) return;
  const types = ["decision", "constraint", "active_work", "problem", "goal", "note", "caveat"];
  openModal("Add memory", `
    <label>Type<select name="type">${types.map((t) => `<option value="${t}">${t}</option>`).join("")}</select></label>
    <label>Content<textarea name="content" rows="5" placeholder="What should future agents remember?"></textarea></label>
  `, async (data) => {
    await api("/api/memories", { method: "POST", body: JSON.stringify({ project_id: pid, type: data.type, content: data.content }) });
    selectProject(pid);
    showToast("Memory added");
  });
});

$("#project-md").addEventListener("input", (e) => {
  $("#project-md-preview").innerHTML = md(e.target.value);
});

$("#save-md-btn").addEventListener("click", async () => {
  const pid = state.activeProjectId;
  if (!pid) return;
  await api(`/api/projects/${pid}/context`, {
    method: "PUT",
    body: JSON.stringify({ content: $("#project-md").value }),
  });
  showToast("PROJECT.md saved");
});

// --- Copy / export ---
$("#copy-link-btn").addEventListener("click", () => {
  if (!state.activeChatId) return;
  copyText(`${location.origin}/?chat=${state.activeChatId}`, "Link");
});

$("#copy-context-btn").addEventListener("click", async () => {
  let ctx = state.agentContextCache[state.activeChatId];
  if (!ctx?.paste_text) ctx = await api(`/api/chats/${state.activeChatId}/agent-context`);
  if (ctx?.paste_text) copyText(ctx.paste_text, "Agent context");
});

$("#copy-project-context-btn").addEventListener("click", async () => {
  let ctx = state.agentContextCache[`p${state.activeProjectId}`];
  if (!ctx?.paste_text) ctx = await api(`/api/projects/${state.activeProjectId}/agent-context`);
  if (ctx?.paste_text) copyText(ctx.paste_text, "Project context");
});

function friendlySessionTitle(title) {
  let t = (title || "").trim();
  if (!t) return "";
  // First-message titles are often the whole user paste — shorten for the log.
  if (t.length > 72) t = t.slice(0, 69).replace(/\s+\S*$/, "").trim() + "…";
  t = t.replace(/^@\S+\s+/, "");
  return t;
}

function renderLogEntry(e) {
  const when = formatDate(e.occurred_at || e.updated_at);
  const title = friendlySessionTitle(e.title);
  const body = (e.summary || "").trim() || title || "Session saved.";
  const metaBits = [when, title].filter(Boolean);
  return `
    <button type="button" class="left-off-entry" data-goto-chat="${e.chat_id || ""}">
      <span class="left-off-entry-meta">${metaBits.map(escapeHtml).join(" · ")}</span>
      <div class="left-off-entry-body">${escapeHtml(body)}</div>
    </button>`;
}

function bindLogEntryClicks(root) {
  $$(`${root} [data-goto-chat]`).forEach((b) => {
    if (!b.dataset.gotoChat) return;
    b.addEventListener("click", () => {
      switchTab("archive");
      selectChat(+b.dataset.gotoChat);
    });
  });
}

async function loadLeftOff(projectId, cached) {
  // Always hit the dedicated endpoint so a stale/partial agent-brief cache
  // cannot leave the panel stuck on the HTML placeholder.
  let data = null;
  try {
    data = await api(`/api/projects/${projectId}/where-left-off`);
  } catch (err) {
    console.warn("logbook fetch failed", err);
    data = cached || null;
  }
  state.leftOffCache = data;
  const headingEl = $("#left-off-heading");
  const latestEl = $("#left-off-latest");
  const logEl = $("#left-off-log");
  if (!latestEl || !logEl) {
    console.warn("logbook DOM nodes missing");
    return;
  }
  if (headingEl) headingEl.textContent = data?.heading || "Logbook";
  if (!data) {
    latestEl.classList.add("muted");
    latestEl.textContent = "Could not load logbook.";
    logEl.innerHTML = "";
    return;
  }
  const entries = data.entries || [];
  const latest = data.latest || entries[0] || null;
  // Prefer the dedicated human left-off field; never show raw agent pickup here.
  const leftOffText = (
    data.where_left_off ||
    latest?.summary ||
    ""
  ).trim();
  if (leftOffText) {
    const when = formatDate(latest?.occurred_at || latest?.updated_at || data.saved_at);
    latestEl.classList.remove("muted");
    latestEl.innerHTML = `
      <div class="left-off-spotlight${latest?.chat_id ? " is-clickable" : ""}" ${latest?.chat_id ? `data-goto-chat="${latest.chat_id}"` : ""}>
        <span class="left-off-entry-meta">${escapeHtml(when || "Most recent session")}</span>
        <div class="left-off-entry-body">${escapeHtml(leftOffText)}</div>
      </div>`;
    bindLogEntryClicks("#left-off-latest");
  } else {
    latestEl.classList.add("muted");
    latestEl.textContent = "Nothing saved yet — /save after a chat to fill this in.";
  }

  const rest = entries.length > 1 ? entries.slice(1) : [];
  if (!entries.length) {
    logEl.innerHTML = `<p class="muted">Earlier sessions will show up here after more saves.</p>`;
    return;
  }
  if (!rest.length) {
    logEl.innerHTML = `<p class="muted">Only one session so far.</p>`;
    return;
  }
  logEl.innerHTML = rest.map((e) => renderLogEntry(e)).join("");
  bindLogEntryClicks("#left-off-log");
}

$("#copy-agent-start-btn").addEventListener("click", async () => {
  const pid = state.activeProjectId;
  if (!pid) return;
  let brief = state.agentBriefCache;
  if (!brief?.agent_prompt) {
    const p = state.activeProject;
    brief = await api(`/api/projects/${p?.slug || pid}/agent-brief`);
    state.agentBriefCache = brief;
  }
  const prompt =
    state.leftOffCache?.pickup ||
    brief?.where_we_left_off?.pickup ||
    brief?.pickup_prompt ||
    brief?.agent_prompt;
  if (prompt) copyText(prompt, "Pickup prompt");
});

$("#copy-full-brief-btn").addEventListener("click", async () => {
  const pid = state.activeProjectId;
  if (!pid) return;
  let brief = state.agentBriefCache;
  if (!brief?.brief_md) {
    const p = state.activeProject;
    brief = await api(`/api/projects/${p?.slug || pid}/agent-brief`);
    state.agentBriefCache = brief;
  }
  const text = brief?.brief_md || "";
  if (text) copyText(text, "Full brief");
});

$("#toggle-archived-btn").addEventListener("click", () => {
  $("#project-chats-list").classList.toggle("hidden");
});

$("#refresh-brief-btn").addEventListener("click", async () => {
  const pid = state.activeProjectId;
  if (!pid) return;
  await api(`/api/projects/${pid}/distill`, { method: "POST" });
  await selectProject(pid);
  showToast("Brief refreshed");
});

$("#export-md-btn").addEventListener("click", () => {
  const c = state.activeChat;
  if (!c) return;
  let body = `# ${chatTitle(c)}\n\n${c.content || ""}\n\n---\n\n`;
  (c.messages || []).forEach((m) => {
    body += `## ${m.role}\n\n${m.content}\n\n`;
  });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([body], { type: "text/markdown" }));
  a.download = `chat-${c.id}.md`;
  a.click();
});

$("#refresh-index-btn").addEventListener("click", async () => {
  const data = await api("/api/index?regenerate=true");
  $("#index-content").innerHTML = md(data.content);
  showToast("Index refreshed");
});

$("#copy-client-setup-prompt-btn").addEventListener("click", async () => {
  const setup = await loadClientSetup();
  await copyText(setup.agent_prompt, "Setup prompt");
});

$("#copy-onboarding-url-btn").addEventListener("click", async () => {
  await copyText(`${API}/api/onboarding`, "Onboarding API URL");
});

$$(".tab").forEach((t) => t.addEventListener("click", () => switchTab(t.dataset.tab)));
$("#add-kanban-column-btn").addEventListener("click", () => {
  const form = $("#add-kanban-column-form");
  const opening = form.classList.contains("hidden");
  form.classList.toggle("hidden", !opening);
  $("#add-kanban-column-btn").setAttribute("aria-expanded", String(opening));
  if (opening) $("#kanban-column-name").focus();
});
$("#add-kanban-column-form").addEventListener("submit", async (event) => {
  event.preventDefault(); const form = event.currentTarget; const label = $("#kanban-column-name").value.trim(); if (!label) return;
  try {
    const data = await api("/api/kanban/columns", { method: "POST", body: JSON.stringify({ label, description: $("#kanban-column-description").value.trim() }) });
    state.kanbanColumns = data.columns; form.reset(); form.classList.add("hidden"); $("#add-kanban-column-btn").setAttribute("aria-expanded", "false"); renderKanban(); showToast(`${label} column added`);
  } catch (error) { showToast(`Could not add column: ${error.message}`); }
});
function searchKindsForTab(tab) {
  if (tab === "projects" || tab === "kanban") return "project";
  if (tab === "archive") return "memory,chat,message";
  return null; // all
}

function searchPlaceholderForTab(tab) {
  if (tab === "projects" || tab === "kanban") return "Search projects…";
  if (tab === "skills") return "Search skills…";
  if (tab === "archive") return "Search memories, sessions…";
  return "Search…";
}

let _searchTimer = null;
$("#search").addEventListener("input", () => {
  clearTimeout(_searchTimer);
  const q = ($("#search").value || "").trim();
  if (state.tab === "kanban" || state.tab === "skills") {
    state.searchResults = null;
    renderSidebar();
    if (state.tab === "kanban") renderKanban();
    else renderSkills();
    return;
  }
  if (q.length >= 3) {
    _searchTimer = setTimeout(() => runGlobalSearch(q), 350);
  } else {
    state.searchResults = null;
    renderSidebar();
  }
});
$("#search").addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    $("#search").value = "";
    state.searchResults = null;
    renderSidebar();
  }
});

// --- Init ---
(async function init() {
  await loadData();
  const params = new URLSearchParams(location.search);
  const pathSlug = decodeURIComponent(location.pathname.replace(/^\/+|\/+$/g, ""));
  const pathProject = pathSlug && !pathSlug.includes("/")
    ? state.projects.find((project) => project.slug === pathSlug)
    : null;
  if (pathProject) {
    switchTab("projects");
    await selectProject(pathProject.id);
  } else if (params.get("chat")) {
    switchTab("archive");
    await selectChat(+params.get("chat"));
  } else if (params.get("project")) {
    switchTab("projects");
    await selectProject(+params.get("project"));
  } else {
    const tab = params.get("tab") || "kanban";
    switchTab(tab);
    if (state.tab === "home") showHome();
    else if (state.tab === "setup") showSetup();
    else if (state.tab === "kanban") showKanban();
    else if (state.tab === "skills") showSkills();
    else if (state.tab === "projects") showClassicProjects();
    else hideViews(), $("#empty-state").classList.remove("hidden");
  }
})();
