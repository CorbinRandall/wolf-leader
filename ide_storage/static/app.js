const API = window.location.origin;

let state = {
  tab: "projects",
  chats: [],
  archivedChats: [],
  projects: [],
  activeChatId: null,
  activeProjectId: null,
  activeChat: null,
  activeProject: null,
  agentContextCache: {},
  onboardingCache: null,
  searchResults: null,
  searchMode: "keyword",
  clientSetupCache: null,
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
  if (params.project) u.set("project", params.project);
  if (params.tab && params.tab !== "home") u.set("tab", params.tab);
  const qs = u.toString();
  history.replaceState(null, "", qs ? `?${qs}` : location.pathname);
}

function hideViews() {
  $("#empty-state").classList.add("hidden");
  $$(".view").forEach((v) => v.classList.add("hidden"));
}

// --- Navigation ---
function switchTab(tab) {
  state.tab = tab;
  state.searchResults = null;
  $("#search").value = "";
  $("#search").placeholder = searchPlaceholderForTab(tab);
  $$(".tab").forEach((t) => t.classList.toggle("active", t.dataset.tab === tab));
  renderSidebar();
  if (tab === "home") showHome();
  else if (tab === "setup") showSetup();
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
  const [chats, archived, projects] = await Promise.all([
    api("/api/chats?limit=500"),
    api("/api/chats?limit=500&include_archived=true&status=archived"),
    api("/api/projects?limit=200"),
  ]);
  state.chats = chats.chats || [];
  state.archivedChats = archived.chats || [];
  state.projects = projects.projects || [];
  renderSidebar();
}

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

// --- Project ---
async function selectProject(id) {
  state.activeProjectId = id;
  state.activeChatId = null;
  renderSidebar();
  hideViews();
  $("#project-view").classList.remove("hidden");
  setUrl({ project: id, tab: "projects" });
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
  const purpose = briefData?.purpose_summary || project.description || "";
  if (purpose) {
    purposeEl.textContent = purpose;
    purposeEl.classList.remove("hidden");
  } else {
    purposeEl.textContent = "";
    purposeEl.classList.add("hidden");
  }

  if (briefData) {
    $("#brief-meta").textContent = [
      briefData.brief_updated_at && `Brief updated: ${formatDate(briefData.brief_updated_at)}`,
      briefData.spec_yaml && `${briefData.spec_yaml.length} char SPEC`,
      briefData.archived_session_count != null && `${briefData.archived_session_count} archived sessions`,
      briefData.memory_count != null && `${briefData.memory_count} memories`,
    ].filter(Boolean).join(" · ");
    const preview = briefData.spec_yaml
      ? `## SPEC.yaml\n\n\`\`\`yaml\n${briefData.spec_yaml}\n\`\`\``
      : (briefData.brief_md || "");
    $("#agent-brief-preview").innerHTML = md(preview);
  } else {
    $("#brief-meta").textContent = "No brief yet — click Refresh brief.";
    $("#agent-brief-preview").innerHTML = `<p class="muted">Run distill to generate AGENT_BRIEF.md.</p>`;
  }

  $("#project-md").value = mdData.content || "";
  $("#project-md-preview").innerHTML = md(mdData.content);

  $("#memories-list").innerHTML = (memories.memories || []).length
    ? memories.memories.map((m) => `
      <div class="memory-item" data-mid="${m.id}">
        <span class="memory-type">${escapeHtml(m.type)}</span>
        <span class="memory-body">${escapeHtml(m.content)}</span>
        <button type="button" class="btn-icon del-memory" data-mid="${m.id}" title="Delete">×</button>
      </div>`).join("")
    : `<p class="muted">No typed memories yet.</p>`;

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

function openModal(title, fields, onSave) {
  $("#modal-title").textContent = title;
  $("#modal-body").innerHTML = fields;
  modal.showModal();
  $("#modal-form").onsubmit = async (e) => {
    e.preventDefault();
    const data = {};
    $("#modal-body").querySelectorAll("[name]").forEach((el) => {
      data[el.name] = el.value;
    });
    await onSave(data);
    modal.close();
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
    <label>Status<select name="status"><option value="active"${p.status !== "archived" ? " selected" : ""}>active</option><option value="archived"${p.status === "archived" ? " selected" : ""}>archived</option></select></label>
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

$("#copy-agent-start-btn").addEventListener("click", async () => {
  const pid = state.activeProjectId;
  if (!pid) return;
  let brief = state.agentBriefCache;
  if (!brief?.agent_prompt) {
    const p = state.activeProject;
    brief = await api(`/api/projects/${p?.slug || pid}/agent-brief`);
    state.agentBriefCache = brief;
  }
  const prompt = brief?.pickup_prompt || brief?.agent_prompt;
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
function searchKindsForTab(tab) {
  if (tab === "projects") return "project";
  if (tab === "archive") return "memory,chat,message";
  return null; // all
}

function searchPlaceholderForTab(tab) {
  if (tab === "projects") return "Search projects…";
  if (tab === "archive") return "Search memories, sessions…";
  return "Search…";
}

let _searchTimer = null;
$("#search").addEventListener("input", () => {
  clearTimeout(_searchTimer);
  const q = ($("#search").value || "").trim();
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
  if (params.get("chat")) {
    switchTab("archive");
    await selectChat(+params.get("chat"));
  } else if (params.get("project")) {
    switchTab("projects");
    await selectProject(+params.get("project"));
  } else {
    const tab = params.get("tab") || "projects";
    switchTab(tab);
    if (state.tab === "home") showHome();
    else if (state.tab === "setup") showSetup();
    else if (state.tab === "projects") {
      hideViews();
      $("#empty-state").classList.remove("hidden");
      $("#empty-state").querySelector("p").textContent =
        "Select a project — agent brief and memories are the canonical context.";
    } else hideViews(), $("#empty-state").classList.remove("hidden");
  }
})();
