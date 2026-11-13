// A child process that speaks one JSON object per line, and JSON-RPC on top of that.
import spawn from "cross-spawn";
import type { ChildProcess } from "node:child_process";
import { toolEnv } from "./agents";

export class JSONLines {
  private child: ChildProcess;
  private buffer = "";
  private tail: string[] = [];
  onMessage: (message: any) => void = () => {};
  onExit: (code: number, tail: string) => void = () => {};

  constructor(executable: string, args: string[], cwd: string) {
    // cross-spawn runs Windows .cmd shims (npm-installed tools) with their arguments intact.
    this.child = spawn(executable, args, { cwd, env: toolEnv(), stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
    this.child.stdout!.setEncoding("utf8");
    this.child.stdout!.on("data", (chunk: string) => {
      this.buffer += chunk;
      let newline: number;
      while ((newline = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, newline).trim();
        this.buffer = this.buffer.slice(newline + 1);
        if (!line.startsWith("{")) continue;
        let message: any;
        try {
          message = JSON.parse(line);
        } catch {
          continue;
        }
        try {
          this.onMessage(message);
        } catch (error) {
          console.error("couldn't handle an agent message:", error);
        }
      }
    });
    this.child.stderr!.setEncoding("utf8");
    this.child.stderr!.on("data", (chunk: string) => {
      this.tail.push(...chunk.split("\n").map((l) => l.trim()).filter(Boolean));
      this.tail = this.tail.slice(-20);
    });
    this.child.on("error", (error) => this.onExit(-1, String(error.message || error)));
    this.child.on("close", (code) => this.onExit(code ?? 0, this.tail.slice(-6).join(" ")));
  }

  get running(): boolean {
    return this.child.exitCode === null && !this.child.killed;
  }

  send(message: any): void {
    if (!this.running) return;
    try {
      this.child.stdin!.write(JSON.stringify(message) + "\n");
    } catch {}
  }

  stop(): void {
    try {
      this.child.kill();
    } catch {}
  }
}

/** JSON-RPC over a JSONLines process. Codex's app-server leaves out the "jsonrpc" field; ACP requires it. */
export class JSONRPCPeer {
  private nextID = 1;
  private waiting = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }>();
  onNotification: (method: string, params: any) => void = () => {};
  onRequest: (id: any, method: string, params: any) => void = () => {};
  onExit: (reason: string | null) => void = () => {};

  constructor(public process: JSONLines, private tagged: boolean) {
    process.onMessage = (m) => this.handle(m);
    process.onExit = (code, tail) => {
      for (const [, w] of this.waiting) {
        clearTimeout(w.timer);
        w.reject(new Error(tail || "The agent stopped."));
      }
      this.waiting.clear();
      this.onExit(code === 0 ? null : tail || `The agent stopped (exit ${code}).`);
    };
  }

  private wrap(message: any) {
    return this.tagged ? { jsonrpc: "2.0", ...message } : message;
  }

  request(method: string, params: any, timeoutMs = 120_000): Promise<any> {
    const id = this.nextID++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiting.delete(id);
        reject(new Error(`The agent didn't answer ${method}.`));
      }, timeoutMs);
      this.waiting.set(id, { resolve, reject, timer });
      this.process.send(this.wrap({ id, method, params }));
    });
  }

  notify(method: string, params?: any): void {
    this.process.send(this.wrap(params === undefined ? { method } : { method, params }));
  }

  respond(id: any, result: any): void {
    this.process.send(this.wrap({ id, result }));
  }

  respondError(id: any, message: string): void {
    this.process.send(this.wrap({ id, error: { code: -32601, message } }));
  }

  private handle(m: any): void {
    if (m.id !== undefined && m.method === undefined) {
      const w = this.waiting.get(m.id);
      if (!w) return;
      this.waiting.delete(m.id);
      clearTimeout(w.timer);
      if (m.error) w.reject(new Error(m.error.message || "The agent refused."));
      else w.resolve(m.result ?? {});
    } else if (m.id !== undefined) {
      this.onRequest(m.id, m.method, m.params ?? {});
    } else if (m.method) {
      this.onNotification(m.method, m.params ?? {});
    }
  }
}
