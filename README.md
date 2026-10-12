<p align="center">
  <img src="installer/assets/app-icon.png" width="140" alt="Wolf Leader">
</p>

<h1 align="center">Wolf Leader</h1>

<p align="center">
  <b>Shared project memory for every AI agent you use.</b><br>
  Self-hosted · works with Cursor, Claude Code and anything that speaks MCP or HTTP
</p>

<p align="center">
  <a href="../../releases/latest"><b>Download for Windows or Mac</b></a> ·
  <a href="#easy-install">Install</a> ·
  <a href="#how-it-works">How it works</a>
</p>

---

AI chats normally start without the context from your earlier work. Wolf Leader gives your agents
one shared memory for each project. It keeps decisions, fixes, open work and past sessions on a hub
you control, so another agent or computer can pick up where you stopped.

Wolf Leader is useful if you switch between AI tools, work from more than one computer, or want a
searchable record of what your agents changed and why. Your agents connect through MCP or HTTP, and
the desktop app helps you install, browse and manage the system.

## Find old work without hunting through chats

Open a brand-new chat in any project and ask:

> what did we work on in the billing service around March 3?

Your agent can search the stored project history and load the useful decisions, fixes and open
work. You do not need to find the original chat or paste its context into a new one.

## How it works

The client integration teaches your agent when to load and save project context. Most of this
happens in the background:

| When | What the agent does |
|---|---|
| Chat starts | Finds the Wolf Leader project for this folder and loads its memories. If there isn't one, it asks before creating it. |
| Something durable happens | Saves it as a typed memory: `decision`, `constraint`, `problem`, `goal`, `active_work`, `note`, `caveat`. |
| After meaningful work | Checkpoints the session. The same chat updates one record and stays with its project. |
| Anything unclear | Hub unreachable, two projects could match, a rename or merge: it tells you and asks. |

Each save updates typed memories, search data and the project's brief. Optional integrations can
also write Obsidian notes and publish a local wiki.

### Pick up on any machine

- **`/wolfhowl`** broadcasts a session: save, git state, file catalog and vault notes, then offers to
  commit, push to your share's git remote and index the files.
- **`/wolfeat`** pulls the latest context for this project onto another machine: brief, memories,
  recent howls with their git commits, and missing files from the share.

When network shares are enabled, project history can live in bare Git repositories on your own
share (`<share>/wolf-leader/git/<slug>.git`). A GitHub account is optional.

## Easy install

**Download** the installer from the [latest release](../../releases/latest), or from a clone:

| | |
|---|---|
| **Windows** | Double-click `start.bat`. It builds `dist\WolfLeaderSetup-<version>.exe` (installing Inno Setup if needed) and runs it. |
| **Mac** | Open the `.dmg` and drag **Wolf Leader** to Applications. Setup runs in the app on first launch, then it becomes your dashboard: stats, recent chats, projects, search, shares and updates. From a clone, double-click `start.command` or run `bash installer/mac/build-app.sh` (macOS 14+, Xcode or Command Line Tools). First launch: right-click → Open (macOS 15+: System Settings → Privacy & Security → Open Anyway). |

The wizard takes a few minutes:

1. **Choose your hub.** Connect to an existing Wolf Leader server, update this computer, or start a
   new hub here with Docker.
2. **What do you want?** Client skills and rule, network shares, Git and Python, Obsidian
   (recommended), the wiki (highly recommended).
3. **Ask your AI agent.** Copy the prompt into Cursor, Claude or ChatGPT on this computer. It backs
   up your current configs, checks what's installed and replies with a strict INI file
   ([format](installer/CONFIG.md)). Paste or load the reply.
4. **Share passwords.** Typed into the installer, never into the AI chat.
5. **Git name and email.** Real or made-up, so local commits never stop to ask for a GitHub login.
6. **Install.** Setup backs up everything it touches first and leaves a restore script to undo it.

## Run the hub

The hub is a Docker stack: FastAPI REST and web UI on `:6971`, MCP on `:6972/mcp`, Postgres with
pgvector, and a nightly backup.

```bash
cp .env.example .env                 # set IDE_STORAGE_PUBLIC_URL to how clients reach the hub
docker compose -f docker-compose.postgres.yml up -d --build
```

- **Tested setup:** an always-on box (NAS, Proxmox LXC or Linux server) with an SMB share for the
  vault, project mirrors, backups and git remotes. Walkthrough: [docs/lxc-hub.md](docs/lxc-hub.md).
- **Docker on your desktop** works the same way but is experimental: the hub is only up while your
  computer is.
- Already have chats? `scripts/wolf-backfill.py` imports existing Cursor and Claude Code sessions
  into grouped projects.
- Migrating from the earlier SQLite setup? Follow the
  [migration and rollback guide](docs/migrating-from-sqlite.md). The original folder is kept for
  rollback.

Times shown to humans are local, `HH:MM MM/DD/YYYY`, using `WOLF_TZ`.

## Connect an agent by hand

```json
{
  "mcpServers": {
    "wolf-leader": { "url": "http://wolf.local:6972/mcp" }
  }
}
```

Then copy `examples/cursor/rules/wolf-leader-hub.mdc` into `~/.cursor/rules/` and the skills in
`examples/cursor/skills/` into `~/.cursor/skills/`. The installer does all of this for you.

| Port | Service |
|---|---|
| 6971 | REST API, web UI, agent brief URLs, wiki at `/wiki/` |
| 6972 | MCP tools at `/mcp` |

Useful endpoints: `GET /health`, `GET /api/search?q=…` (hybrid keyword and vector),
`GET /api/projects/{slug}/agent-brief`, `POST /api/projects/ensure`.

## Development and local use

| File | Use |
|---|---|
| `docker-compose.postgres.yml` | Recommended: Postgres + pgvector, vault, wiki |
| `docker-compose.dev.yml` | Live-mount source for development |
| `run-local.sh` / `stop-local.sh` | No Docker: Python 3.11+ on one machine |

More detail: [INSTALL.md](INSTALL.md).

## Your data stays yours

Memories live in the hub's database on your own hardware. Nothing is sent anywhere else. The repo
never contains runtime data: `.env`, `data/` and the vault are gitignored. Back up the hub's data
folder (the Postgres stack does this nightly to the share).

## Project

Wolf Leader is built and maintained by Corbin Randall. Contributions and bug reports are welcome
through this repository.
