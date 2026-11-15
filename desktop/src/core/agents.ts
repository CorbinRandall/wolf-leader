// The AI tools Wolf Leader can run, and how to find them on this computer.
// The list follows the Mac app's (which follows the agents t3code supports).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export type AgentProtocol = "claude" | "codex" | "acp";

export interface AgentKind {
  id: string;
  name: string;
  company: string;
  binary: string;
  args: string[];
  proto: AgentProtocol;
  /** How to install or sign in, shown when the tool isn't found. */
  installHint: string;
}

export const AGENTS: AgentKind[] = [
  { id: "claude", name: "Claude", company: "Anthropic", binary: "claude", args: [], proto: "claude",
    installHint: "Install Claude Code, then run `claude` once to sign in." },
  { id: "codex", name: "Codex", company: "OpenAI", binary: "codex", args: ["app-server"], proto: "codex",
    installHint: "Install the Codex CLI, then run `codex login`." },
  { id: "gemini", name: "Gemini", company: "Google", binary: "gemini", args: ["--experimental-acp"], proto: "acp",
    installHint: "Install the Gemini CLI (npm i -g @google/gemini-cli), then run `gemini` once to sign in." },
  { id: "grok", name: "Grok", company: "xAI", binary: "grok", args: ["--permission-mode", "default", "agent", "stdio"], proto: "acp",
    installHint: "Install the Grok CLI, then sign in." },
  { id: "opencode", name: "OpenCode", company: "SST", binary: "opencode", args: ["acp"], proto: "acp",
    installHint: "Install OpenCode, then run `opencode auth login`." },
  { id: "kiro", name: "Kiro", company: "Amazon", binary: "kiro-cli", args: ["acp", "--agent-engine=v3", "--auth-method=cli"], proto: "acp",
    installHint: "Install the Kiro CLI, then run `kiro-cli login`." },
  { id: "fx", name: "Fx", company: "Fx", binary: "fx", args: ["acp"], proto: "acp", installHint: "Install the fx CLI, then sign in." },
  { id: "copilot", name: "Copilot", company: "GitHub", binary: "copilot", args: ["--acp"], proto: "acp",
    installHint: "Install the GitHub Copilot CLI (npm i -g @github/copilot), then sign in." },
];

export const agentByID = (id: string) => AGENTS.find((a) => a.id === id);

/** Apps opened from the desktop get a bare PATH, so look in the usual places too. */
export function searchDirs(): string[] {
  const home = os.homedir();
  const dirs: string[] = [];
  if (process.platform === "win32") {
    const appData = process.env.APPDATA || path.join(home, "AppData", "Roaming");
    const local = process.env.LOCALAPPDATA || path.join(home, "AppData", "Local");
    dirs.push(
      path.join(home, ".local", "bin"), path.join(appData, "npm"), path.join(local, "Programs", "claude"),
      path.join(home, ".bun", "bin"), path.join(local, "pnpm"), path.join(home, "scoop", "shims"),
      path.join(local, "Microsoft", "WinGet", "Links"), path.join(home, ".opencode", "bin"), path.join(home, ".volta", "bin"),
    );
  } else {
    dirs.push(
      `${home}/.local/bin`, `${home}/.npm-global/bin`, `${home}/.bun/bin`, `${home}/.opencode/bin`, `${home}/.claude/local`,
      `${home}/.volta/bin`, `${home}/Library/pnpm`, `${home}/.yarn/bin`, `${home}/.asdf/shims`, `${home}/.kiro/bin`,
      "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
    );
    // Node version managers put npm-installed CLIs next to node.
    const nvm = `${home}/.nvm/versions/node`;
    try {
      for (const v of fs.readdirSync(nvm).sort().reverse()) dirs.push(`${nvm}/${v}/bin`);
    } catch {}
  }
  const inherited = (process.env.PATH || "").split(path.delimiter);
  const seen = new Set<string>();
  return [...dirs, ...inherited].filter((d) => d && !seen.has(d) && seen.add(d));
}

export const searchPath = () => searchDirs().join(path.delimiter);

export function findTool(binary: string): string | null {
  const exts = process.platform === "win32" ? [".exe", ".cmd", ".bat", ""] : [""];
  for (const dir of searchDirs()) {
    for (const ext of exts) {
      const candidate = path.join(dir, binary + ext);
      try {
        if (fs.statSync(candidate).isFile()) return candidate;
      } catch {}
    }
  }
  return null;
}

export function toolEnv(): NodeJS.ProcessEnv {
  // Tells the tools' own Wolf Leader hooks (installed for using them outside the app) that this
  // chat is Wolf Leader's: it saves itself and already has its context.
  return { ...process.env, PATH: searchPath(), WOLF_LEADER_IN_APP: "1" };
}

export interface FoundAgent extends AgentKind {
  found: boolean;
}

export function scanAgents(): FoundAgent[] {
  return AGENTS.map((a) => ({ ...a, found: findTool(a.binary) !== null }));
}
