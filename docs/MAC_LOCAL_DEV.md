# Wolf Leader — Mac local dev setup

Paste this entire document into a **new Cursor chat** on your Mac with folder **`~/dev/wolf-leader`** open (local, not Remote-SSH).

---

## Goal

Run Wolf Leader on your Mac (Docker), develop and test fast, push to GitHub, deploy to corbox only when ready.

Production hub stays at **`http://192.168.1.221:6971`**. Mac dev uses **`http://127.0.0.1:6971`**.

---

## Prerequisites

- Docker Desktop installed and running
- Git + SSH access to `github.com:CorbinRandall/wolf-leader`
- Cursor on Mac (this chat)

---

## Step 1 — Clone repo

```bash
mkdir -p ~/dev
git clone git@github.com:CorbinRandall/wolf-leader.git ~/dev/wolf-leader
cd ~/dev/wolf-leader
```

Open **`~/dev/wolf-leader`** in Cursor (File → Open Folder).

---

## Step 2 — Local hub (.env + Docker)

```bash
cd ~/dev/wolf-leader
cp .env.example .env
```

Edit `.env`:

```bash
IDE_STORAGE_PUBLIC_URL=http://127.0.0.1:6971
IDE_STORAGE_MCP_URL=http://127.0.0.1:6972/mcp
IDE_STORAGE_HOST_LABEL=mac-dev
```

Start hub:

```bash
chmod +x scripts/*.sh scripts/lib/*.sh 2>/dev/null || true
./scripts/setup.sh
```

Verify:

```bash
curl -s http://127.0.0.1:6971/health
open http://127.0.0.1:6971/?tab=setup
```

Rebuild after code changes:

```bash
docker compose up -d --build
```

---

## Step 3 — Cursor client → local hub

Run on Mac (not SSH):

```bash
WOLF_LEADER_API=http://127.0.0.1:6971 \
WOLF_LEADER_MCP=http://127.0.0.1:6972/mcp \
WORKSPACE="$HOME/dev/wolf-leader" \
  bash -c "$(curl -fsSL http://127.0.0.1:6971/api/client-setup/install.sh)"
```

Or from repo checkout:

```bash
cd ~/dev/wolf-leader
WOLF_LEADER_API=http://127.0.0.1:6971 \
WOLF_LEADER_MCP=http://127.0.0.1:6972/mcp \
WORKSPACE="$HOME/dev/wolf-leader" \
  ./scripts/install-cursor-client.sh
```

Verify:

```bash
./scripts/verify-cursor-client.sh
```

**Reload Cursor window** — `/save` and `/new` should appear.

---

## Step 4 — Optional: import Mac transcripts into local hub

Create `docker-compose.local.yml` (gitignored overrides are fine):

```yaml
services:
  wolf-leader:
    environment:
      CURSOR_TRANSCRIPTS_ROOT: /transcripts
    volumes:
      - ${HOME}/.cursor/projects/Users-YOURUSER-dev-wolf-leader/agent-transcripts:/transcripts:ro
```

Find your actual path:

```bash
ls ~/.cursor/projects/
```

Then:

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build
```

---

## Step 5 — Daily dev loop

1. Edit code in `~/dev/wolf-leader`
2. `docker compose up -d --build`
3. Test at http://127.0.0.1:6971
4. Commit and push:

```bash
git add -A && git commit -m "your message" && git push origin main
```

---

## Step 6 — Deploy to corbox (production) when ready

From Mac, after `git push`:

```bash
ssh root@192.168.1.230 'cd /opt/wolf-leader && git pull && bash scripts/deploy-wolf-leader-lxc.sh'
```

Production URL: http://192.168.1.221:6971/health

Other clients (Unraid, etc.) keep using **`192.168.1.221`** — no change unless you intentionally point them at your Mac.

---

## Agent instructions (for this chat)

You are setting up Wolf Leader local dev on macOS.

1. Run Step 1–3 commands; fix any errors.
2. Confirm `curl http://127.0.0.1:6971/health` and Setup tab loads.
3. Confirm `verify-cursor-client.sh` passes.
4. Use MCP `wolf-leader` at `http://127.0.0.1:6972/mcp` for project work in this repo.
5. Do **not** deploy to corbox unless I ask.

Report: Docker status, health URL, verify output, and whether `/save` `/new` appear after reload.
