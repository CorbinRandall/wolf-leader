#!/usr/bin/env bash
# Move an original Wolf Leader hub (SQLite, CorbinRandall/wolf-leader) to this version
# (Postgres + share), or go back. Guided; run it on the computer that runs the hub:
#
#   bash wolf-og-migrate.sh
#
# Upgrade: installs the new hub in "<original folder>-v2", stops the original container and
#          renames it wolf-leader-og (kept for rollback), copies the data in. The original
#          folder is not modified. Do this BEFORE running the installer on any client.
# Revert:  stops the new hub (its database is kept), optionally copies everything saved since
#          the upgrade back into the original database (old file backed up first), and starts
#          the original container again.
#
# Without prompts (the Wolf Leader app runs it this way):
#   wolf-og-migrate.sh --upgrade --yes [--old DIR] [--url URL] [--share DIR] [--replace]
#   wolf-og-migrate.sh --revert  --yes [--old DIR] [--new DIR] [--bring yes|no]
# Add --ssh USER@HOST [--ssh-port N] [--ssh-key PATH] to run it on the hub computer from here:
# the script copies itself there over SSH (key login only, never a password) and runs there.
set -euo pipefail
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"

REPO="https://github.com/Vapor-Nexus/wolf-leader"
BRANCH="${WOLF_BRANCH:-feat/background-memory-installer}"

ACTION="" YES=0 A_OLD="" A_NEW="" A_URL="" A_SHARE="" A_BRING="" A_REPLACE=0
SSH_TARGET="" SSH_PORT="" SSH_KEY=""
PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --upgrade) ACTION=upgrade; PASS+=("$1"); shift ;;
    --revert) ACTION=revert; PASS+=("$1"); shift ;;
    --yes) YES=1; PASS+=("$1"); shift ;;
    --replace) A_REPLACE=1; PASS+=("$1"); shift ;;
    --old) A_OLD="$2"; PASS+=("$1" "$2"); shift 2 ;;
    --new) A_NEW="$2"; PASS+=("$1" "$2"); shift 2 ;;
    --url) A_URL="$2"; PASS+=("$1" "$2"); shift 2 ;;
    --share) A_SHARE="$2"; PASS+=("$1" "$2"); shift 2 ;;
    --bring) A_BRING="$2"; PASS+=("$1" "$2"); shift 2 ;;
    --ssh) SSH_TARGET="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="${2/#\~/$HOME}"; shift 2 ;;
    *) printf 'ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -n "$SSH_TARGET" ]; then
  SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
  [ -n "$SSH_PORT" ] && SSH+=(-p "$SSH_PORT")
  [ -n "$SSH_KEY" ] && SSH+=(-i "$SSH_KEY")
  printf '==> Connecting to %s over SSH\n' "$SSH_TARGET"
  "${SSH[@]}" "$SSH_TARGET" 'cat > /tmp/wolf-og-migrate.sh && chmod 700 /tmp/wolf-og-migrate.sh' < "$0" \
    || { printf 'ERROR: could not log in to %s with an SSH key (no passwords are used)\n' "$SSH_TARGET" >&2; exit 4; }
  REMOTE="bash /tmp/wolf-og-migrate.sh"
  for a in ${PASS[@]+"${PASS[@]}"}; do REMOTE+=" $(printf '%q' "$a")"; done
  exec "${SSH[@]}" "$SSH_TARGET" "$REMOTE"
fi

PY="$(mktemp -t wolf-og-migrate.XXXXXX)"
trap 'rm -f "$PY"' EXIT

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
step() { STEP=$((STEP + 1)); printf '\n==> [%s/%s] %s\n' "$STEP" "$TOTAL" "$*"; }
ask() {
  if [ "$YES" = 1 ]; then printf '%s' "$2"; return; fi
  local a; read -r -p "$1 [${2}]: " a </dev/tty; printf '%s' "${a:-$2}"
}
yes_no() {
  if [ "$YES" = 1 ]; then [[ "$2" =~ ^[Yy] ]]; return; fi
  local a; read -r -p "$1 [${2}]: " a </dev/tty; a="${a:-$2}"; [[ "$a" =~ ^[Yy] ]]
}

env_get() { [ -f "$1" ] && grep -E "^$2=" "$1" | tail -n 1 | cut -d= -f2- || true; }
env_set() {
  local tmp; tmp="$(mktemp)"
  awk -v k="$2" -v v="$3" 'BEGIN{d=0} $0 ~ "^"k"=" {print k"="v; d=1; next} {print} END{if(!d) print k"="v}' "$1" > "$tmp"
  mv "$tmp" "$1"
}
label_dir() { docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$1" 2>/dev/null || true; }
exists() { docker inspect "$1" >/dev/null 2>&1; }

wait_health() {
  local port="$1"
  for _ in $(seq 1 120); do
    curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1 && return 0
    sleep 5
  done
  die "hub did not answer on port $port; see: docker logs wolf-leader"
}

# Runs inside the new hub container. MODE=import copies OG_DB (a copy) into Postgres;
# MODE=export writes Postgres back into OG_DB (a copy of the original file).
cat > "$PY" <<'PYEOF'
import os, sqlite3, sys
import psycopg
from ide_storage.db import database_url, init_db

TABLES = ("projects", "chats", "messages", "memories")
mode = os.environ["MODE"]
path = os.environ["OG_DB"]
if not os.path.isfile(path):
    sys.exit(f"ERROR: no SQLite database at {path}")

def clean(v):
    return v.replace("\x00", "") if isinstance(v, str) else v

def lite_cols(db, t):
    return [r[1] for r in db.execute(f"PRAGMA table_info({t})")]

def pg_cols(cur, t):
    cur.execute("SELECT column_name FROM information_schema.columns "
                "WHERE table_schema='public' AND table_name=%s", (t,))
    return [r[0] for r in cur.fetchall()]

init_db()
lite = sqlite3.connect(path)
lite.execute("PRAGMA wal_checkpoint(TRUNCATE)")
lite.row_factory = sqlite3.Row
pg = psycopg.connect(database_url())
cur = pg.cursor()

if mode == "import":
    for t in ("projects", "chats", "memories"):
        cur.execute(f"SELECT COUNT(*) FROM {t}")
        if cur.fetchone()[0]:
            if os.environ.get("REPLACE") != "1":
                print(f"    the new hub already has data in '{t}'", flush=True)
                sys.exit(3)
            cur.execute("TRUNCATE projects, chats, messages, memories, project_paths, howls, "
                        "jobs, fs_catalog, file_chunks, knowledge_revisions, embeddings "
                        "RESTART IDENTITY CASCADE")
            break
    pids, cids, slugs = set(), set(), set()
    for t in TABLES:
        cols = [c for c in lite_cols(lite, t) if c in set(pg_cols(cur, t))]
        rows = []
        for r in (lite.execute(f"SELECT {', '.join(cols)} FROM {t} ORDER BY id") if "id" in cols else []):
            d = {c: clean(r[c]) for c in cols}
            if t == "projects":
                if d.get("slug"):
                    if d["slug"] in slugs:
                        d["slug"] = f"{d['slug']}-{d['id']}"
                    slugs.add(d["slug"])
                d["path"] = d.get("path") or ""
                pids.add(d["id"])
            elif t == "chats":
                if d.get("project_id") not in pids:
                    d["project_id"] = None
                d["content"] = d.get("content") or ""
                cids.add(d["id"])
            elif t == "messages" and d.get("chat_id") not in cids:
                continue
            elif t == "memories":
                if d.get("project_id") not in pids:
                    continue
                if d.get("source_chat_id") not in cids:
                    d["source_chat_id"] = None
            rows.append(tuple(d[c] for c in cols))
        if rows:
            cur.executemany(f"INSERT INTO {t} ({', '.join(cols)}) VALUES ({', '.join(['%s'] * len(cols))})", rows)
        cur.execute(f"SELECT setval(pg_get_serial_sequence('{t}','id'), COALESCE(MAX(id),1), MAX(id) IS NOT NULL) FROM {t}")
        print(f"    {t}: {len(rows)}", flush=True)
    pg.commit()
    pg.close()
    init_db()
    try:
        from ide_storage.vault import refresh_vault, write_project_note
        for pid in sorted(pids):
            write_project_note(pid)
        refresh_vault()
        print("    vault notes written", flush=True)
    except Exception as exc:
        print(f"    vault notes skipped: {exc}", flush=True)

elif mode == "export":
    lite.execute("PRAGMA foreign_keys=OFF")
    for t in reversed(TABLES):
        lite.execute(f"DELETE FROM {t}")
    for t in TABLES:
        cols = [c for c in pg_cols(cur, t) if c in set(lite_cols(lite, t))]
        cur.execute(f"SELECT {', '.join(cols)} FROM {t} ORDER BY id")
        rows = cur.fetchall()
        if rows:
            lite.executemany(f"INSERT INTO {t} ({', '.join(cols)}) VALUES ({', '.join(['?'] * len(cols))})", rows)
        print(f"    {t}: {len(rows)}", flush=True)
    try:
        lite.execute("DELETE FROM embeddings")
    except sqlite3.DatabaseError:
        pass
    lite.commit()
    pg.close()

lite.close()
print("OK", flush=True)
PYEOF

run_py() {  # run_py MODE /data/path/in/container [extra -e args...]
  local mode="$1" db="$2"; shift 2
  docker exec -i -e MODE="$mode" -e OG_DB="$db" "$@" wolf-leader python - < "$PY"
}

# --------------------------------------------------------------------------- upgrade
upgrade() {
  local guess="" OLD NEW SHARE PORT MCP_PORT URL MCP_URL BASE REPLACE=0
  if exists wolf-leader; then
    guess="$(label_dir wolf-leader)"
    [ -f "$guess/data/ide-work.db" ] || guess=""
  fi
  say ""
  say "Where is your original Wolf Leader? (the folder with docker-compose.yml and data/ide-work.db)"
  OLD="${A_OLD:-$(ask "Original folder" "${guess:-$HOME/wolf-leader}")}"
  OLD="$(cd "$OLD" 2>/dev/null && pwd)" || die "folder not found"
  [ -f "$OLD/data/ide-work.db" ] || die "no data/ide-work.db in $OLD"
  NEW="${OLD%/}-v2"

  PORT="$(env_get "$OLD/.env" PORT)"; PORT="${PORT:-6971}"
  MCP_PORT="$(env_get "$OLD/.env" MCP_PORT)"; MCP_PORT="${MCP_PORT:-6972}"
  URL="$(env_get "$OLD/.env" IDE_STORAGE_PUBLIC_URL)"
  say ""
  say "The address other computers use to reach this hub (keep it the same as before)."
  URL="${A_URL:-$(ask "Hub address" "${URL:-http://$(hostname):$PORT}")}"; URL="${URL%/}"
  MCP_URL="$(env_get "$OLD/.env" IDE_STORAGE_MCP_URL)"
  if [ -z "$MCP_URL" ]; then
    BASE="$URL"; [[ "$BASE" =~ :[0-9]+$ ]] && BASE="${BASE%:*}"
    MCP_URL="$BASE:$MCP_PORT/mcp"
  fi

  SHARE="$NEW/share"; [ -d /srv/wolf ] && [ -w /srv/wolf ] && SHARE=/srv/wolf
  say ""
  say "The share folder: the new version keeps its Obsidian vault and backups in"
  say "<share>/wolf-leader/. Share this folder over SMB so other computers can map it."
  SHARE="${A_SHARE:-$(ask "Share folder" "$SHARE")}"

  say ""
  say "Plan:"
  say "  original (left as is):  $OLD"
  say "  new hub goes in:        $NEW"
  say "  share folder:           $SHARE  (creates wolf-leader/vault and wolf-leader/hub)"
  say "  hub address:            $URL   MCP: $MCP_URL"
  say "  original container:     stopped and renamed wolf-leader-og (revert brings it back)"
  yes_no "Go ahead?" "y" || die "cancelled"

  TOTAL=9; STEP=0
  step "Checking Docker"
  command -v docker >/dev/null || die "docker is not installed"
  docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"
  command -v curl >/dev/null || die "curl is required"

  step "Getting the new Wolf Leader ($BRANCH)"
  if [ -f "$NEW/docker-compose.postgres.yml" ]; then
    say "    already in $NEW, reusing it"
  else
    [ ! -e "$NEW" ] || [ -z "$(ls -A "$NEW")" ] || die "$NEW exists and is not empty"
    if command -v git >/dev/null; then
      git clone --depth 1 --branch "$BRANCH" "$REPO.git" "$NEW"
    else
      mkdir -p "$NEW"
      curl -fsSL "https://codeload.github.com/${REPO#https://github.com/}/tar.gz/refs/heads/$BRANCH" \
        | tar xz --strip-components=1 -C "$NEW"
    fi
  fi

  step "Creating share folders"
  mkdir -p "$SHARE/wolf-leader/vault" "$SHARE/wolf-leader/hub" "$NEW/pgdata" "$NEW/data/og"
  SHARE="$(cd "$SHARE" && pwd)"

  step "Writing settings ($NEW/.env)"
  if [ ! -f "$NEW/.env" ]; then
    cp "$NEW/.env.example" "$NEW/.env"
    env_set "$NEW/.env" POSTGRES_PASSWORD "$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32 || true)"
  fi
  env_set "$NEW/.env" IDE_STORAGE_PUBLIC_URL "$URL"
  env_set "$NEW/.env" IDE_STORAGE_MCP_URL "$MCP_URL"
  env_set "$NEW/.env" PORT "$PORT"
  env_set "$NEW/.env" MCP_PORT "$MCP_PORT"
  env_set "$NEW/.env" WOLF_PGDATA "$NEW/pgdata"
  env_set "$NEW/.env" WOLF_SHARE_ROOT "$SHARE"
  env_set "$NEW/.env" IDE_STORAGE_SHARE_ROOT "$SHARE"
  env_set "$NEW/.env" IDE_STORAGE_VAULT_DIR "$SHARE/wolf-leader/vault"
  local tz; tz="$(env_get "$OLD/.env" WOLF_TZ)"; [ -z "$tz" ] || env_set "$NEW/.env" WOLF_TZ "$tz"

  step "Stopping the original hub"
  if exists wolf-leader && [ "$(label_dir wolf-leader)" != "$NEW" ]; then
    exists wolf-leader-og && die "a container named wolf-leader-og already exists; remove or rename it first"
    docker stop wolf-leader >/dev/null
    docker rename wolf-leader wolf-leader-og
    say "    stopped; kept as wolf-leader-og"
  else
    say "    nothing to stop"
  fi

  step "Copying the original data"
  cp -p "$OLD/data/ide-work.db" "$NEW/data/og/"
  for f in "$OLD/data/ide-work.db-wal" "$OLD/data/ide-work.db-shm"; do
    if [ -f "$f" ]; then cp -p "$f" "$NEW/data/og/"; fi
  done
  if [ -d "$OLD/data/projects" ]; then
    mkdir -p "$NEW/data/projects"
    cp -Rp "$OLD/data/projects/." "$NEW/data/projects/"
  fi

  step "Building and starting the new hub (first build takes several minutes)"
  (cd "$NEW" && docker compose -f docker-compose.postgres.yml up -d --build)
  wait_health "$PORT"

  step "Importing projects, chats and memories"
  local rc=0
  run_py import /data/og/ide-work.db || rc=$?
  if [ "$rc" = 3 ]; then
    [ "$A_REPLACE" = 1 ] || yes_no "Replace the new hub's data with the original's? (wipes what the new hub has)" "n" \
      || die "the new hub already has data; import skipped (pass --replace to overwrite it)"
    run_py import /data/og/ide-work.db -e REPLACE=1
  elif [ "$rc" != 0 ]; then
    die "import failed (output above); the original is untouched, run Revert to go back"
  fi

  step "Rebuilding search vectors"
  docker exec wolf-leader python -m ide_storage.backfill_embeddings >/dev/null \
    && say "    done" || say "    skipped; keyword search still works"

  say ""
  say "Upgrade done. New hub: $URL   (runs from $NEW)"
  say "Share $SHARE over SMB (e.g. as \"wolf\"), then run the Wolf Leader installer on each"
  say "computer and choose \"connect\". To go back, run this script again and pick Revert."
}

# --------------------------------------------------------------------------- revert
revert() {
  local NEW OLD PORT BRING=1 STAMP
  exists wolf-leader-og || die "no wolf-leader-og container found; there is nothing to revert to"
  say ""
  OLD="${A_OLD:-$(ask "Original folder" "$(label_dir wolf-leader-og)")}"
  OLD="$(cd "$OLD" 2>/dev/null && pwd)" || die "original folder not found"
  NEW="${A_NEW:-$(ask "New hub folder" "${OLD%/}-v2")}"
  NEW="$(cd "$NEW" 2>/dev/null && pwd)" || die "new hub folder not found"
  [ -f "$OLD/data/ide-work.db" ] || die "no data/ide-work.db in $OLD"
  PORT="$(env_get "$NEW/.env" PORT)"; PORT="${PORT:-6971}"

  say ""
  say "Anything saved since the upgrade lives only in the new hub."
  case "$A_BRING" in
    yes) BRING=1 ;;
    no) BRING=0 ;;
    *) yes_no "Copy it back into the original database? (the current file is backed up first)" "y" || BRING=0 ;;
  esac
  say ""
  say "Plan:"
  say "  stop the new hub in $NEW (its database stays in $NEW/pgdata)"
  if [ "$BRING" = 1 ]; then say "  copy projects, chats and memories back into $OLD/data/ide-work.db"; fi
  say "  start the original container again (wolf-leader-og -> wolf-leader)"
  yes_no "Go ahead?" "y" || die "cancelled"

  TOTAL=$((2 + 2 * BRING)); STEP=0
  STAMP="$(date +%Y%m%d-%H%M%S)"
  if [ "$BRING" = 1 ]; then
    step "Copying data from the new hub back into the original database"
    exists wolf-leader && [ "$(label_dir wolf-leader)" = "$NEW" ] \
      || (cd "$NEW" && docker compose -f docker-compose.postgres.yml up -d)
    wait_health "$PORT"
    mkdir -p "$NEW/data/og-revert"
    rm -f "$NEW/data/og-revert/"ide-work.db*
    for f in ide-work.db ide-work.db-wal ide-work.db-shm; do
      if [ -f "$OLD/data/$f" ]; then cp -p "$OLD/data/$f" "$NEW/data/og-revert/"; fi
    done
    run_py export /data/og-revert/ide-work.db
  fi

  step "Stopping the new hub"
  (cd "$NEW" && docker compose -f docker-compose.postgres.yml down)

  if [ "$BRING" = 1 ]; then
    step "Putting the updated database in place"
    mkdir -p "$OLD/data/backup-$STAMP"
    for f in ide-work.db ide-work.db-wal ide-work.db-shm; do
      if [ -f "$OLD/data/$f" ]; then mv "$OLD/data/$f" "$OLD/data/backup-$STAMP/"; fi
    done
    cp -p "$NEW/data/og-revert/ide-work.db" "$OLD/data/ide-work.db"
    say "    previous file kept in $OLD/data/backup-$STAMP/"
  fi

  step "Starting the original hub"
  docker rename wolf-leader-og wolf-leader
  docker start wolf-leader >/dev/null
  wait_health "$PORT"

  say ""
  say "Reverted. The original hub is running from $OLD."
  say "Computers set up with the new installer still have the new skills/rule; they will keep"
  say "saving, but features the original lacks (/wolfhowl, /wolfeat) will not work there."
  say "To upgrade again later, run this script and pick Upgrade."
}

if [ -z "$ACTION" ]; then
  [ "$YES" = 0 ] || die "--yes needs --upgrade or --revert"
  say "Wolf Leader: original <-> new hub"
  say "  1) Upgrade the original Wolf Leader on this computer to the new version"
  say "  2) Revert to the original Wolf Leader"
  case "$(ask "Choose" "1")" in
    1) ACTION=upgrade ;;
    2) ACTION=revert ;;
    *) die "pick 1 or 2" ;;
  esac
fi
"$ACTION"
