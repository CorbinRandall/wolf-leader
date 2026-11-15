"""Run Wolf Leader MCP on a separate port (avoids FastAPI/Starlette conflicts)."""
import os

from .mcp_server import mcp

if __name__ == "__main__":
    from .access import AccessMiddleware, serve

    host = os.environ.get("MCP_HOST", "0.0.0.0")
    port = int(os.environ.get("MCP_PORT", "6972"))
    public = os.environ.get("WOLF_MCP_PUBLIC_PORT", "").strip()
    app = AccessMiddleware(mcp.http_app(path="/mcp", transport="streamable-http"))
    serve(app, host, port, int(public) if public.isdigit() else None)
