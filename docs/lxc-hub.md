# Run the Wolf Leader hub in a Proxmox LXC

One LXC. Postgres + pgvector on its own local disk. One shared drive, hosted by the same LXC,
that every client maps: project repos, the Obsidian vault, and database backups.

Placeholders used below: `<proxmox-host>` (your Proxmox node), `<ctid>` (the container id you pick),
`<hub-ip>` (the container's LAN address), `<password>` (the share password the setup generates).

| What | Where |
|---|---|
| Hub UI / REST | `http://wolf.local:6971` |
| MCP | `http://wolf.local:6972/mcp` |
| Wiki (Fumadocs, Halo theme) | `http://wolf.local:6971/wiki/` |
| The drive | `\\wolf.local\wolf` → map as `W:` (user `wolf`, password in the hub `.env`) |
| Project repos | `W:\<repo>` (= `/srv/wolf/<repo>` on the hub) |
| Obsidian vault | `W:\wolf-leader\vault` (open this folder in Obsidian) |
| Database backups | `W:\wolf-leader\hub\wolf-leader-YYYY-MM-DD.dump` (nightly, 14 kept) |
| Postgres data | `/var/lib/wolf-postgres` inside the LXC — its own disk, never shared |
| Code + `.env` in the LXC | `/opt/wolf-leader` |

If mDNS does not work on your network, use `http://<hub-ip>:6971` / `\\<hub-ip>\wolf` instead of `wolf.local`.

## 1. Create the container

On your Proxmox host (adjust storage, size and bridge to taste). Docker needs `nesting=1`.

```bash
CTID=<ctid>
pveam update
TEMPLATE=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | tail -n1)
pveam download local "$TEMPLATE"
pct create $CTID "local:vztmpl/$TEMPLATE" \
  --hostname wolf --cores 2 --memory 4096 --swap 1024 \
  --rootfs local-lvm:16 \
  --mp1 local-lvm:500,mp=/srv/wolf,backup=1 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --features nesting=1,keyctl=1 --unprivileged 1 --onboot 1
pct start $CTID
```

Inside the container (`pct enter <ctid>`): install Docker and publish `wolf.local` over mDNS.

```bash
apt-get update && apt-get install -y curl git avahi-daemon
curl -fsSL https://get.docker.com | sh
sed -i 's/^#\?host-name=.*/host-name=wolf/; s/^#\?allow-interfaces=.*/allow-interfaces=eth0/' /etc/avahi/avahi-daemon.conf
systemctl enable --now avahi-daemon && systemctl restart avahi-daemon
```

## 2. Get the code and start the Postgres stack

```bash
git clone https://github.com/<owner>/wolf-leader.git /opt/wolf-leader
cd /opt/wolf-leader
cp .env.example .env        # set POSTGRES_PASSWORD and the public URLs (http://wolf.local:6971 etc.)
docker compose -f docker-compose.postgres.yml up -d --build
curl -s http://127.0.0.1:6971/health
```

## 3. Add the Postgres disk and the Samba share

Back on the Proxmox host, run `scripts/wolf-lxc-storage.sh` from a checkout. It is idempotent and
defaults to a dry run.

```bash
WOLF_CT=<ctid> bash scripts/wolf-lxc-storage.sh            # shows what it would do
WOLF_CT=<ctid> bash scripts/wolf-lxc-storage.sh --apply
```

It adds a second disk (`mp2`, 100G by default, `WOLF_PG_SIZE_GB` to change) at `/var/lib/wolf-postgres`,
makes sure `mp1` is mounted at `/srv/wolf`, installs Samba with a single `[wolf]` share for user `wolf`
(random password written to `WOLF_SHARE_PASSWORD` in `/opt/wolf-leader/.env`), points the hub `.env`
at both paths, and restarts the stack.

## Why the database is not on the drive

Postgres refuses to start unless it owns its data directory. Network shares (SMB, NFS with squash)
stamp their own owner on every file, so a Postgres data directory on a share does not work anywhere,
on any NAS. The database lives on a local disk and its backups go on the drive.

## Skills

* `/save` — light checkpoint.
* `/wolfhowl` — save + this machine's path alias + git state + embed + file catalog + Obsidian notes;
  mirrors the repo's files to `W:\wolf-leader\projects\<slug>\`; then *offers* commit/push, ingest
  cited file bodies, start a job. Guide: `/api/howl-guide`.
* `/wolfeat` — pull brief, memories, howls (with git SHAs), related notes, open jobs; then *offers*
  `git pull`, register path, read file bodies, model pull. Guide: `/api/eat-guide`.

Installed by the client bundle (`bash -c "$(curl -fsSL http://wolf.local:6971/api/client-setup/install.sh)"`).
Also available as MCP tools `wolfhowl` / `wolfeat`.

## Client setup (Windows)

```powershell
net use W: \\wolf.local\wolf /user:wolf <password> /persistent:yes
git config --global --add safe.directory '*'   # repos on a network drive are owned by the server
```

## Client setup (Mac)

Terminal, one block. Replace `<password>` with `WOLF_SHARE_PASSWORD` from the hub `.env`.

```bash
# 1. Mount the drive at /Volumes/wolf (add it to Login Items afterwards so it re-mounts)
open "smb://wolf:<password>@wolf.local/wolf"
git config --global --add safe.directory '*'

# 2. Install the client bundle (skills, rule, MCP entry, hub URLs) — no hooks by default
mkdir -p /tmp/wl && curl -fsSL http://wolf.local:6971/api/client-bundle.tar.gz | tar xz -C /tmp/wl
WOLF_LEADER_API=http://wolf.local:6971 WOLF_LEADER_MCP=http://wolf.local:6972/mcp \
  bash /tmp/wl/scripts/install-cursor-client.sh

# 3. Backfill every Cursor / Claude Code chat on this Mac since a date (dry run first)
python3 /tmp/wl/scripts/wolf-backfill.py --since 2026-01-01 --dry-run
python3 /tmp/wl/scripts/wolf-backfill.py --since 2026-01-01
```

Reload Cursor. From then on the agent saves in the background through MCP and tells you in one line.
To merge several folders into one project, pass `--map groups.json` (format in the script's docstring).

## Background saving (how it works)

No hooks, no scripts. The `wolf-leader-hub.mdc` rule tells every agent to `resolve_project` at start
(asking before `create_project` if the folder is new), `remember` durable facts as they happen, and
`save_session` after each meaningful step and at least every ~8 turns. Each save runs the full
pipeline on the hub. The agent reports each save in one line and asks before anything bigger.
Shell hooks are opt-in: `WOLF_LEADER_HOOKS=1` at install time.

## Redeploy code

If the container has a git checkout, pull and rebuild from your Proxmox host:

```bash
WOLF_LEADER_VMID=<ctid> bash /opt/wolf-leader/scripts/deploy-wolf-leader-lxc.sh
```

Without git in the container, push a tarball from a client checkout instead:

```bash
tar -czf /tmp/wl.tgz $(git ls-files -co --exclude-standard)
scp /tmp/wl.tgz root@<proxmox-host>:/tmp/
ssh root@<proxmox-host> "pct push <ctid> /tmp/wl.tgz /tmp/wl.tgz && pct exec <ctid> -- bash -c 'tar -xzf /tmp/wl.tgz -C /opt/wolf-leader && bash /opt/wolf-leader/scripts/lxc-deploy.sh'"
```

`scripts/lxc-deploy.sh` normalises line endings, runs `docker compose -f docker-compose.postgres.yml up -d --build`, and prints `/health`.

## Connectors

Set `WOLF_CONNECTORS` in `.env` (JSON): `ollama` hosts (`model_pull`, `model_list`) and `http` probes.
Jobs live in the `jobs` table, run in the hub, and show up in `/wolfeat` (`open_jobs`) and `GET /api/jobs`.
The hub never hosts models itself.
