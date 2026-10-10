# Wolf Leader — project context

This file links this compose stack to the Wolf Leader hub (self-reference when the hub tracks itself).

| Field | Value |
|-------|-------|
| **slug** | `wolf-leader` |
| **Mode** | `compose_maintain` |
| **Web UI** | http://YOUR_HOST:6971/?project=wolf-leader |

## Agent pickup

1. MCP `wolf-leader` → `set_project({ slug: "wolf-leader" })` → `get_brief()` or `recall()`
2. Fallback (same host): `curl -s http://127.0.0.1:6971/api/projects/wolf-leader/agent-brief`
