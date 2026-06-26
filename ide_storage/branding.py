"""Product branding — user-facing names for Wolf Leader."""

PRODUCT_NAME = "Wolf Leader"
PRODUCT_TAGLINE = "AI Project Storage"
PRODUCT_DESCRIPTION = (
    "Self-hosted AI project storage — memories, checkpoints, and handoff for agents "
    "across any IDE, CLI, or automation tool."
)

# MCP key in client config (mcp.json, claude mcp add, etc.)
MCP_SERVER_KEY = "wolf-leader"

# Default slug for this hub when installed as its own project
HUB_SLUG = "wolf-leader"

# Older installs / pasted context may still use these
LEGACY_HUB_SLUGS = frozenset({"ide-storage", "ide_storage"})

# Docker service id, health check, loggers
SERVICE_ID = "wolf-leader"
