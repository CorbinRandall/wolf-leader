// The app's main process: one window, and the requests the screens can make of the core.
import { app, BrowserWindow, dialog, ipcMain, Menu, nativeTheme, shell } from "electron";
import fs from "node:fs";
import path from "node:path";
import { Store } from "../core/store";

let window: BrowserWindow | null = null;
let store: Store;
const pending = new Map<string, NodeJS.Timeout>();

function send(channel: string, payload: any): void {
  if (window && !window.isDestroyed()) window.webContents.send(`wolf:${channel}`, payload);
}

function chatList() {
  return [...store.records.values()]
    .sort((a, b) => b.updated - a.updated)
    .map((r) => ({
      id: r.id, title: r.title, agentID: r.agentID, projectID: r.projectID ?? null, projectName: r.projectName ?? null,
      updated: r.updated, messages: r.items.filter((i) => i.kind === "user").length,
      running: store.isRunning(r.id),
      needsYou: store.isRunning(r.id) && r.items.some((i) => i.kind === "approval" && i.status === "pending"),
      device: r.agentDevice ?? null,
    }));
}

async function state() {
  return {
    version: app.getVersion(), platform: process.platform,
    config: { ...store.config, hubURL: store.config.hubURL, hubDisplay: store.hub.display },
    agents: store.agents, rules: store.rules, hubOK: await store.hub.healthy(), chats: chatList(),
  };
}

const handlers: Record<string, (...args: any[]) => any> = {
  state,
  refresh: async () => {
    await store.refresh();
    return state();
  },
  "hub.get": (p: string) => store.hub.get(p, 60_000),
  "hub.request": (method: string, p: string, body?: any) => store.hub.request(method, p, body, 60_000),
  "config.set": (changes: any) => {
    store.setConfig(changes);
    return state();
  },
  "chat.get": (id: string) => {
    const session = store.session(id);
    return session ? { record: session.record, busy: session.busy } : null;
  },
  "chat.start": (fresh: any, text: string, files: string[] = []) => {
    const session = store.create(fresh);
    session.send(text, files);
    send("list", chatList());
    return session.record.id;
  },
  "chat.send": (id: string, text: string, files: string[] = []) => store.session(id)?.send(text, files),
  "chat.answer": (id: string, item: string, allow: boolean, always = false) => store.session(id)?.answer(item, allow, always),
  "chat.stop": (id: string) => store.session(id)?.interrupt(),
  "chat.set": (id: string, changes: any) => store.session(id)?.set(changes),
  "chat.switchAgent": (id: string, agentID: string) => store.session(id)?.switchAgent(agentID),
  "chat.attach": (id: string, project: any) => store.session(id)?.attach(project),
  "chat.remove": (id: string) => store.remove(id),
  "files.pick": async () => {
    const result = await dialog.showOpenDialog(window!, { properties: ["openFile", "multiSelections"] });
    return result.canceled ? [] : result.filePaths;
  },
  "open.external": (url: string) => (/^https?:\/\//.test(url) ? shell.openExternal(url) : undefined),
  "export.all": async () => {
    const reply = await fetch(store.hub.url("/api/export.zip"), { signal: AbortSignal.timeout(600_000) });
    if (!reply.ok) throw new Error("The hub couldn't make the export.");
    const stamp = new Date().toISOString().slice(0, 10);
    let target = path.join(app.getPath("downloads"), `wolf-leader-export-${stamp}.zip`);
    for (let n = 2; fs.existsSync(target); n++) target = path.join(app.getPath("downloads"), `wolf-leader-export-${stamp} ${n}.zip`);
    fs.writeFileSync(target, Buffer.from(await reply.arrayBuffer()));
    shell.showItemInFolder(target);
    return path.basename(target);
  },
};

function createWindow(): void {
  window = new BrowserWindow({
    width: 1280, height: 820, minWidth: 880, minHeight: 560, show: false,
    backgroundColor: "#0b1220", title: "Wolf Leader",
    titleBarStyle: process.platform === "darwin" ? "hiddenInset" : "default",
    webPreferences: { preload: path.join(__dirname, "preload.js"), contextIsolation: true, nodeIntegration: false, sandbox: false },
  });
  window.loadFile(path.join(__dirname, "index.html"));
  window.once("ready-to-show", () => {
    if (!process.env.WOLF_SHOTS) window?.show();
  });
  // Links in a chat open in the person's browser, never inside the app.
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//.test(url)) shell.openExternal(url);
    return { action: "deny" };
  });
  window.webContents.on("will-navigate", (event, url) => {
    if (!url.startsWith("file:")) {
      event.preventDefault();
      if (/^https?:\/\//.test(url)) shell.openExternal(url);
    }
  });
  window.on("closed", () => (window = null));
}

/** For checking the screens without a person: WOLF_SHOTS=<folder> saves a picture of each and quits. */
async function takeShots(folder: string): Promise<void> {
  fs.mkdirSync(folder, { recursive: true });
  const routes = (process.env.WOLF_ROUTES || "home,settings").split(",");
  const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
  await wait(Number(process.env.WOLF_WAIT || 3500));
  // WOLF_TEST_SEND="<agent>|<message>": run one real chat first, and picture it when it's done.
  if (process.env.WOLF_TEST_SEND) {
    const [agentID, text] = process.env.WOLF_TEST_SEND.split("|");
    const session = store.create({ agentID });
    session.send(text);
    for (let i = 0; i < 240 && session.busy; i++) await wait(500);
    console.log("TEST CHAT", JSON.stringify(session.record.items.map((i) => [i.kind, i.status ?? "", i.text.slice(0, 120)])));
    routes.push(`chat:${session.record.id}`);
    await wait(2500); // let it reach the hub
  }
  for (const route of routes) {
    await window!.webContents.executeJavaScript(`window.__nav && window.__nav(${JSON.stringify(route)})`);
    await wait(Number(process.env.WOLF_WAIT || 2500));
    const image = await window!.webContents.capturePage();
    fs.writeFileSync(path.join(folder, `${route.replace(/[^a-z0-9-]+/gi, "_")}.png`), image.toPNG());
  }
  app.quit();
}

app.whenReady().then(async () => {
  nativeTheme.themeSource = "dark";
  store = new Store(process.env.WOLF_LEADER_HOME || path.join(app.getPath("userData"), "data"));
  store.onChat = (snapshot) => {
    // Streamed words arrive many times a second; pass them on in small batches.
    const id = snapshot.record.id;
    if (pending.has(id)) return;
    pending.set(id, setTimeout(() => {
      pending.delete(id);
      const session = store.session(id);
      if (session) send("chat", { record: session.record, busy: session.busy });
      send("list", chatList());
    }, 80));
  };
  store.onList = () => send("list", chatList());
  ipcMain.handle("wolf", async (_event, name: string, ...args: any[]) => {
    const handler = handlers[name];
    if (!handler) throw new Error(`Unknown request: ${name}`);
    return handler(...args);
  });
  if (process.platform !== "darwin") Menu.setApplicationMenu(null);
  createWindow();
  store.refresh().catch(() => {});
  // Chats follow you: pick up what other devices changed.
  setInterval(() => store.pull().then(() => send("list", chatList())).catch(() => {}), 20_000);
  if (process.env.WOLF_SHOTS) takeShots(process.env.WOLF_SHOTS).catch((error) => { console.error(error); app.quit(); });
  app.on("activate", () => { if (!window) createWindow(); });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
app.on("before-quit", () => store?.stopAll());
