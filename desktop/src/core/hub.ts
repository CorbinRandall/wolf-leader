// A thin client for the hub: its REST API (port 6971) and its MCP endpoint (the port after it).
// A personal hub address carries the person's access key in its path (/k/<key>); both keep it.

export class HubError extends Error {
  constructor(message: string, public status = 0, public body: any = null) {
    super(message);
  }
}

export class Hub {
  private mcpSession: string | null = null;
  private mcpChain: Promise<any> = Promise.resolve();

  constructor(public baseURL: string) {
    this.baseURL = baseURL.trim().replace(/\/+$/, "");
  }

  /** The address without any access key, safe to show. */
  get display(): string {
    return this.baseURL.split("/k/")[0];
  }

  url(path: string): string {
    return this.baseURL + path;
  }

  mcpURL(): string {
    try {
      const u = new URL(this.baseURL);
      u.port = String((Number(u.port) || 6971) + 1);
      u.pathname = u.pathname.replace(/\/+$/, "") + "/mcp";
      return u.toString();
    } catch {
      return this.baseURL + "/mcp";
    }
  }

  async request(method: string, path: string, body?: any, timeoutMs = 30_000): Promise<any> {
    let reply: Response;
    try {
      reply = await fetch(this.url(path), {
        method,
        headers: body === undefined ? undefined : { "Content-Type": "application/json" },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (error: any) {
      throw new HubError(`Can't reach the hub: ${error?.message ?? error}`);
    }
    const text = await reply.text();
    let parsed: any = text;
    try {
      parsed = JSON.parse(text);
    } catch {}
    if (!reply.ok) throw new HubError(`The hub answered with HTTP ${reply.status}.`, reply.status, parsed);
    return parsed;
  }

  get(path: string, timeoutMs = 30_000): Promise<any> {
    return this.request("GET", path, undefined, timeoutMs);
  }

  /** Like get, but null instead of an error: for context that a chat can run without. */
  async tryGet(path: string, timeoutMs = 30_000): Promise<any> {
    try {
      return await this.get(path, timeoutMs);
    } catch {
      return null;
    }
  }

  async healthy(): Promise<boolean> {
    try {
      await this.get("/health", 4000);
      return true;
    } catch {
      return false;
    }
  }

  private async mcpPost(payload: any, session: string | null): Promise<{ text: string; session: string | null; status: number }> {
    const headers: Record<string, string> = { "Content-Type": "application/json", Accept: "application/json, text/event-stream" };
    if (session) headers["mcp-session-id"] = session;
    const reply = await fetch(this.mcpURL(), { method: "POST", headers, body: JSON.stringify(payload), signal: AbortSignal.timeout(120_000) });
    return { text: await reply.text(), session: reply.headers.get("mcp-session-id"), status: reply.status };
  }

  /** Call one of the hub's MCP tools (used to file a chat in its project's logbook). One at a time. */
  callTool(tool: string, args: any): Promise<any> {
    const run = async () => {
      for (const attempt of [1, 2]) {
        if (!this.mcpSession) {
          const hello = await this.mcpPost({ jsonrpc: "2.0", id: 1, method: "initialize", params: {
            protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "wolf-leader-app", version: "3" } } }, null);
          if (!hello.session) throw new HubError("The hub's MCP server didn't start a session.");
          this.mcpSession = hello.session;
          await this.mcpPost({ jsonrpc: "2.0", method: "notifications/initialized" }, this.mcpSession);
        }
        const reply = await this.mcpPost({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: tool, arguments: args } }, this.mcpSession);
        if (reply.status >= 400 && attempt === 1) {
          this.mcpSession = null; // the session expired; start a new one
          continue;
        }
        for (let line of reply.text.split("\n")) {
          line = line.startsWith("data:") ? line.slice(5).trim() : line.trim();
          if (!line.startsWith("{")) continue;
          const result = JSON.parse(line).result ?? {};
          return result.structuredContent && typeof result.structuredContent === "object" ? result.structuredContent : result;
        }
        return {};
      }
      return {};
    };
    const next = this.mcpChain.then(run, run);
    this.mcpChain = next.catch(() => {});
    return next;
  }
}
