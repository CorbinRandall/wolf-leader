# Wolf Leader — First-day setup

Wolf Leader gives AI agents shared project memory. The desktop app is the normal way to install it. Use the command-line server steps only when you are administering a server yourself.

Replace `YOUR_HOST` with the address of the computer running your hub.

| Resource | Address |
|---|---|
| Desktop installers | https://github.com/CorbinRandall/wolf-leader/releases/latest |
| Web dashboard | http://YOUR_HOST:6971 |
| Setup page | http://YOUR_HOST:6971/?tab=setup |
| Setup API | http://YOUR_HOST:6971/api/client-setup |
| MCP | `http://YOUR_HOST:6972/mcp` |

## Day 1: install the app

### Mac

1. Download the latest `.dmg`.
2. Open it and drag **Wolf Leader** to Applications.
3. Open Wolf Leader. If macOS blocks the first launch, right-click the app and choose **Open**.
4. Choose whether to connect to an existing hub or create a new one.
5. Follow the wizard. It backs up files before changing agent settings.

### Windows

1. Download the latest `.exe`.
2. Open it and follow the installer.
3. Launch Wolf Leader and choose whether to connect to an existing hub or create a new one.
4. Follow the wizard. It backs up files before changing agent settings.

The wizard checks the machine, connects the hub, configures available agent clients, and verifies the result. Share passwords are entered into the app, not into an AI chat. Network shares are optional; a remote Wolf Leader server by itself is not a network share.

## Connect an agent

In the desktop app or server dashboard, open **Setup**, click **Copy setup prompt**, and paste it into the agent that owns the workspace. The agent should:

1. Use the absolute project folder that is open in the IDE.
2. Ask for a friendly device name and model policy: economy, balanced, or maximum quality.
3. Add the `wolf-leader` MCP server without replacing unrelated MCP servers.
4. Install `/wolfhowl` and `/wolfeat` for Cursor or Codex. They replace the old `/save` and `/new`, which the installer removes.
5. Install the portable Wolf Howl and Wolf Eat skills into any other skill-capable agent.
6. Add the workspace `AGENTS.md`, recall hooks, and automatic save hooks.
7. Reload the client and verify one test checkpoint reaches the hub.

Codex users must open **Settings → Hooks** and trust all three Wolf Leader hooks. Automatic saves do not run until they are trusted.

## What the two skills do

- `/wolfhowl`: save. It reads the chat from disk, matches it to an existing project, and uploads it with git and file context. If nothing matches, it asks whether this is an existing project or a new one before creating anything.
- `/wolfeat`: recall. It pulls the newest project context onto this machine, or walks through connecting a workspace that is not set up yet.

Older guides mention `/save` and `/new`. `/wolfhowl` now does everything both did.

Portable skills are also available in the dashboard’s **Skills** tab. Download all of them as a ZIP, or use **Copy install prompt** for an agent-specific install.

## Verify setup

- Hub health: `curl -fsS http://YOUR_HOST:6971/health`
- REST bootstrap: `curl -fsS 'http://YOUR_HOST:6971/api/bootstrap?path=/absolute/project/path'`
- MCP: call `resolve_project`, then `recall`
- Confirm all expected slash skills are visible after reloading the agent.
- Confirm the client verifier passes.
- Make one test `/wolfhowl` and confirm it appears in the project.

Setup is incomplete if a skill is missing, MCP points to the wrong host, a Codex hook is untrusted, or the test save does not reach the hub.

## Every work session

1. Start with `resolve_project` and `recall` or `get_brief`.
2. Use `remember` for durable decisions and constraints.
3. Let automatic saves checkpoint meaningful turns.
4. Use `/wolfhowl` for a deliberate checkpoint.
5. Use `/wolfeat` to pick the work up later or on another machine.

## Advanced: run the hub yourself

The desktop wizard is recommended for a first install. Server administrators can deploy from a clone:

```bash
git clone https://github.com/CorbinRandall/wolf-leader.git
cd wolf-leader
cp .env.example .env
# Set IDE_STORAGE_PUBLIC_URL and IDE_STORAGE_MCP_URL in .env
./scripts/setup.sh
```

Open `http://YOUR_HOST:6971/?tab=setup` after the stack starts. Use the LAN, VPN, or reverse-proxy address that client machines can actually reach. Use localhost only when the hub and client are on the same machine.

Back up the hub database and data directory. Runtime data, credentials, private addresses, user names, and machine-specific paths do not belong in tracked example files.
