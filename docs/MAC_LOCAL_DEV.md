# Wolf Leader — macOS local development

Use this guide to run a private development hub on a Mac. Your production hub, if any, stays separate.

## Prerequisites

- Docker Desktop
- Git
- An MCP-capable IDE or agent

## Clone and configure

```bash
mkdir -p "$HOME/dev"
git clone https://github.com/YOUR_GITHUB_USER/wolf-leader.git "$HOME/dev/wolf-leader"
cd "$HOME/dev/wolf-leader"
cp .env.example .env
```

For a Mac-only development hub, keep the loopback defaults in `.env`:

```dotenv
IDE_STORAGE_PUBLIC_HOST=127.0.0.1
IDE_STORAGE_PUBLIC_URL=http://127.0.0.1:6971
IDE_STORAGE_MCP_URL=http://127.0.0.1:6972/mcp
IDE_STORAGE_DEVICE_NAME=mac-dev
IDE_STORAGE_HOST_LABEL=mac-dev
```

If other devices must reach the Mac, run `./scripts/configure-runtime.sh --force`. It detects a Tailscale or LAN address and writes the URLs into the private `.env` file.

## Start and verify

```bash
./scripts/setup.sh
curl -fsS http://127.0.0.1:6971/health
open http://127.0.0.1:6971/?tab=setup
```

Rebuild after code changes with `docker compose up -d --build`.

## Connect the local IDE

Open the Setup tab and click **Copy setup prompt**. The copied prompt contains this hub's configured API and MCP URLs. Paste it into the IDE agent and let it identify the current workspace.

For Cursor, the equivalent command is:

```bash
WOLF_LEADER_API=http://127.0.0.1:6971 \
WOLF_LEADER_MCP=http://127.0.0.1:6972/mcp \
WORKSPACE="$HOME/dev/wolf-leader" \
  bash -c "$(curl -fsSL http://127.0.0.1:6971/api/client-setup/install.sh)"
```

Reload Cursor after installation. Confirm `/save` and `/new` appear. The installed hooks recall project context and save meaningful transcript updates in the background. Use `/save` for a deliberate final checkpoint.

During onboarding, choose a friendly device name, a model policy (economy, balanced, or maximum quality), and whether background saves should remain enabled. Store those choices in the workspace `AGENTS.md`, not in tracked public examples.

## Optional transcript import

Create a gitignored `docker-compose.local.yml` and replace the host path with the transcript directory on this Mac:

```yaml
services:
  wolf-leader:
    environment:
      CURSOR_TRANSCRIPTS_ROOT: /transcripts
    volumes:
      - /absolute/path/to/agent-transcripts:/transcripts:ro
```

Then run:

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build
```

## Deployment

Wolf Leader does not assume a production host. Configure deployment for your environment separately. The public GitHub workflow is manual and opt-in so forks do not wait for someone else's private runner.
