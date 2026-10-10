# Example project — stable facts (do not re-extract each session)

## Purpose
Template for a Docker Compose stack tracked in Wolf Leader.

## Paths
- Compose: `/path/to/your/project`
- Data: project-specific appdata path

## Ports
| Service | Port | Notes |
|---------|------|-------|
| app | 8080 | Web UI |

## Agent workflow
1. MCP `set_project({ slug: "my-slug" })` → `recall()`
2. Read `handoff_tier` before acting
3. `/save` at session end

## Rebuild minimum
```bash
cd /path/to/your/project && docker compose up -d --build
```
