"""Run Wolf Leader MCP on a separate port (avoids FastAPI/Starlette conflicts)."""
import os

from .mcp_server import mcp

if __name__ == "__main__":
    host = os.environ.get("MCP_HOST", "0.0.0.0")
    port = int(os.environ.get("MCP_PORT", "6972"))
    mcp.run(transport="streamable-http", host=host, port=port, path="/mcp")
