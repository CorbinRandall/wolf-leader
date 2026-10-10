#!/bin/bash
# Wolf Leader for macOS: does the actual install. The Wolf Leader app's first-launch setup collects
# the answers and calls this; it can also be run by hand. Contract: installer/CONFIG.md.
# Each phase starts with a "==> <Step name>" line; the app turns those into its live checklist.
#
#   install.sh --ini wolf-leader-setup.ini --mode new|connect|update \
#              [--toggles client,shares,prereqs,obsidian,wiki] \
#              [--git-name "Name" --git-email you@example.com] [--result FILE]
#              [--backup-dir DIR] [--dry-run]
#
# Share passwords never go on the command line: put "shareN=<password>" lines in a mode-600 file
# and pass its path in WL_SECRETS_FILE. This script reads it and deletes it before doing anything.
# Must stay bash 3.2 compatible (the bash macOS ships).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=ini.sh
. "$SCRIPT_DIR/ini.sh"

# --- secrets first: read and delete before anything else can fail or log ---------------------
if [ -n "${WL_SECRETS_FILE:-}" ] && [ -f "$WL_SECRETS_FILE" ]; then
  while IFS= read -r _l || [ -n "$_l" ]; do
    _k=${_l%%=*}
    case "$_k" in share[1-5]) printf -v "SECRET_$_k" '%s' "${_l#*=}" ;; esac
  done <"$WL_SECRETS_FILE"
  rm -f "$WL_SECRETS_FILE"
  unset _l _k
fi
unset WL_SECRETS_FILE

DRY=0
INI=""
MODE=""
TOGGLES="client,shares,prereqs,obsidian,wiki"
GIT_NAME=""
GIT_EMAIL=""
RESULT=""
BACKUP_DIR=""

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ini) INI=${2-}; shift 2 ;;
    --mode) MODE=${2-}; shift 2 ;;
    --toggles) TOGGLES=${2-}; shift 2 ;;
    --git-name) GIT_NAME=${2-}; shift 2 ;;
    --git-email) GIT_EMAIL=${2-}; shift 2 ;;
    --result) RESULT=${2-}; shift 2 ;;
    --backup-dir) BACKUP_DIR=${2-}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$MODE" in new|connect|update) ;; *) echo "--mode must be new, connect or update" >&2; exit 2 ;; esac
[ -n "$INI" ] && [ -f "$INI" ] || { echo "--ini FILE is required (wolf-leader-setup.ini)" >&2; exit 2; }

IS_MAC=0
[ "$(uname -s)" = Darwin ] && IS_MAC=1
if [ "$IS_MAC" = 0 ] && [ "$DRY" = 0 ]; then
  echo "This installer is for macOS. Use --dry-run to preview the steps on another system." >&2
  exit 2
fi

# Apps launched from Finder get a bare PATH; Homebrew and Docker Desktop live outside it.
PATH="/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
export PATH
export HOMEBREW_NO_ENV_HINTS=1 NONINTERACTIVE=1

LOG_DIR="$HOME/Library/Logs/WolfLeader"
LOG="$LOG_DIR/install.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/wolf-leader-install.XXXXXX") || exit 1
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

WARNINGS=0
NOTES=""
WOLF_MOUNT=""

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; }
skip() { printf '  skip  %s\n' "$*"; }
warn() {
  printf '  WARN  %s\n' "$*"
  WARNINGS=$((WARNINGS + 1))
  NOTES="${NOTES}${*}
"
}
note() {
  printf '  note  %s\n' "$*"
  NOTES="${NOTES}${*}
"
}

result() {
  [ -n "$RESULT" ] || return 0
  printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-400)" >>"$RESULT"
}

finish() {
  result status "$1"
  result warnings "$WARNINGS"
  if [ -n "$NOTES" ]; then
    printf '%s' "$NOTES" | while IFS= read -r n; do [ -n "$n" ] && result note "$n"; done
  fi
}

fatal() {
  printf '  FAIL  %s\n' "$*"
  if [ "$DRY" = 1 ]; then
    WARNINGS=$((WARNINGS + 1))
    printf '  (dry-run: a real run would stop here; continuing to show the remaining steps)\n'
    return 0
  fi
  result reason "$*"
  finish fail
  say ""
  say "Install stopped. Log: $LOG"
  exit 1
}

# Print the command, then run it (or only print it in --dry-run).
run() {
  if [ "$DRY" = 1 ]; then
    printf '  [dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  printf '  $'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

run_in() {
  local dir=$1
  shift
  if [ "$DRY" = 1 ]; then
    printf '  [dry-run] (cd %q &&' "$dir"
    printf ' %q' "$@"
    printf ')\n'
    return 0
  fi
  printf '  $ (cd %q &&' "$dir"
  printf ' %q' "$@"
  printf ')\n'
  (cd "$dir" && "$@")
}

# write_file PATH MODE  (content on stdin; never used for secrets)
write_file() {
  local path=$1 mode=$2 content
  content=$(cat)
  if [ "$DRY" = 1 ]; then
    printf '  [dry-run] write %s (mode %s):\n' "$path" "$mode"
    printf '%s\n' "$content" | sed 's/^/      | /'
    return 0
  fi
  mkdir -p "$(dirname "$path")" && printf '%s\n' "$content" >"$path" && chmod "$mode" "$path" \
    && ok "wrote $path"
}

has() { command -v "$1" >/dev/null 2>&1; }

# /usr/bin/git and /usr/bin/python3 are stubs on a Mac without Command Line Tools: running them
# pops Apple's "install developer tools" dialog. Only treat them as present when CLT is installed.
clt_ok() { [ "$IS_MAC" = 1 ] && xcode-select -p >/dev/null 2>&1; }

git_usable() {
  local g
  g=$(command -v git 2>/dev/null) || return 1
  if [ "$IS_MAC" = 1 ] && [ "$g" = /usr/bin/git ]; then clt_ok || return 1; fi
  "$g" --version >/dev/null 2>&1
}

real_python() {
  local p
  p=$(command -v python3 2>/dev/null) || return 1
  if [ "$IS_MAC" = 1 ] && [ "$p" = /usr/bin/python3 ]; then clt_ok || return 1; fi
  "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' >/dev/null 2>&1 || return 1
  printf '%s' "$p"
}

has_toggle() {
  case ",$TOGGLES," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

# --- read the answer file -------------------------------------------------------------------
say "Wolf Leader macOS install  $(date '+%H:%M %m/%d/%Y')$( [ "$DRY" = 1 ] && printf '  (DRY RUN: nothing is changed)')"
say "  source:  $ROOT"
say "  mode:    $MODE"
say "  toggles: ${TOGGLES:-none}"
say "  log:     $LOG"

wl_ini_extract "$INI" >"$WORK/answers.ini"
if ! wl_ini_parse "$WORK/answers.ini" mac >"$WORK/cfg"; then
  say ""
  say "The answer file is not valid:"
  sed 's/^/  /' "$WORK/cfg"
  result reason "answer file is not valid"
  finish fail
  exit 2
fi
wl_cfg_load "$WORK/cfg"

HUB_URL=$(wl_cfg wolf hub_url)
MCP_URL=$(wl_cfg wolf mcp_url)
TZ_NAME=$(wl_cfg wolf timezone)
DEVICE=$(wl_cfg wolf device_name)
SHARES=$(wl_cfg meta shares)
say "  hub:     $HUB_URL  (MCP $MCP_URL)"
say "  device:  $DEVICE, $TZ_NAME"

WL_HOME="$HOME/WolfLeader"
HUB_DIR=""
if [ "$MODE" = new ]; then
  if [ -d "$ROOT/.git" ] && [ -w "$ROOT" ]; then HUB_DIR=$ROOT; else HUB_DIR="$WL_HOME/hub"; fi
fi

# --- save state first: snapshot everything this run may create or overwrite ----------------
# Layout: <backup>/home/<path under $HOME> (or <backup>/root/<absolute path>), manifest.tsv
# listing "existed|created <TAB> relative copy <TAB> original path", and restore.sh to undo.
write_restore_sh() {
  cat >"$1" <<'RESTORE'
#!/bin/bash
# Undo Wolf Leader Setup: puts back the files saved in this folder and removes the ones Setup
# created. Run:  bash restore.sh      (add -y to skip the question)
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
TAB=$(printf '\t')
echo "Wolf Leader restore from: $DIR"
if [ "${1-}" != "-y" ]; then
  printf 'Put back the files Wolf Leader Setup changed? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) echo "Nothing changed."; exit 0 ;; esac
fi
while IFS="$TAB" read -r kind rel path; do
  [ -n "${path:-}" ] || continue
  case "$kind" in
    existed)
      rm -rf "$path"
      mkdir -p "$(dirname "$path")"
      cp -Rp "$DIR/$rel" "$path" && echo "restored  $path"
      ;;
    created)
      if [ -e "$path" ]; then rm -rf "$path" && echo "removed   $path (Setup created it)"; fi
      ;;
  esac
done <"$DIR/manifest.tsv"
echo "Done. Restart Cursor / Claude Code."
echo "Not undone by this script: Keychain passwords, Login Items, mounted shares, installed apps,"
echo "and Docker containers (stop a hub with: docker compose -f docker-compose.postgres.yml down)."
RESTORE
}

snapshot_targets() {
  local d f
  for f in .cursor/mcp.json .cursor/AGENTS.md .cursor/wolf-leader.env .cursor/skills/save-new \
    .claude/skills/save-new .gitconfig; do
    printf '%s\n' "$HOME/$f"
  done
  for f in "$ROOT"/examples/cursor/rules/*.mdc; do
    [ -f "$f" ] && printf '%s\n' "$HOME/.cursor/rules/$(basename "$f")"
  done
  for d in "$ROOT"/examples/cursor/skills/*; do
    [ -d "$d" ] || continue
    printf '%s\n' "$HOME/.cursor/skills/$(basename "$d")" "$HOME/.claude/skills/$(basename "$d")"
  done
  [ -n "$HUB_DIR" ] && printf '%s\n' "$HUB_DIR/.env"
}

if [ -z "$BACKUP_DIR" ]; then
  BACKUP_DIR="$HOME/Library/Application Support/WolfLeader/backup-$(date +%Y%m%d-%H%M)"
  _n=2
  _base=$BACKUP_DIR
  while [ -e "$BACKUP_DIR" ]; do BACKUP_DIR="$_base-$_n"; _n=$((_n + 1)); done
fi

step "Saving current state (undo point)"
if [ "$DRY" = 0 ]; then
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || fatal "could not create the backup folder $BACKUP_DIR"
  : >"$BACKUP_DIR/manifest.tsv"
fi
_saved=0
_new=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in
    "$HOME"/*) rel="home/${p#"$HOME"/}" ;;
    *) rel="root$p" ;;
  esac
  if [ -e "$p" ]; then
    _saved=$((_saved + 1))
    if [ "$DRY" = 1 ]; then
      say "  [dry-run] save $p -> $BACKUP_DIR/$rel"
    else
      mkdir -p "$(dirname "$BACKUP_DIR/$rel")" && cp -Rp "$p" "$BACKUP_DIR/$rel" \
        || fatal "could not back up $p; nothing was changed"
      printf 'existed\t%s\t%s\n' "$rel" "$p" >>"$BACKUP_DIR/manifest.tsv"
    fi
  else
    _new=$((_new + 1))
    if [ "$DRY" = 1 ]; then
      say "  [dry-run] note $p does not exist yet (restore.sh would remove it if Setup creates it)"
    else
      printf 'created\t%s\t%s\n' "$rel" "$p" >>"$BACKUP_DIR/manifest.tsv"
    fi
  fi
done <<EOF
$(snapshot_targets)
EOF
if [ "$DRY" = 1 ]; then
  say "  [dry-run] write $BACKUP_DIR/manifest.tsv and executable $BACKUP_DIR/restore.sh"
else
  write_restore_sh "$BACKUP_DIR/restore.sh" && chmod 755 "$BACKUP_DIR/restore.sh" \
    || fatal "could not write $BACKUP_DIR/restore.sh"
  ok "saved $_saved existing item(s) to $BACKUP_DIR ($_new new path(s) will be removed by restore.sh)"
fi
say "  To undo this install later: bash \"$BACKUP_DIR/restore.sh\""
result backup_dir "$BACKUP_DIR"
unset _n _base _saved _new

AGENT_BACKUP=$(wl_cfg backup path)
case "$AGENT_BACKUP" in "~/"*) AGENT_BACKUP="$HOME/${AGENT_BACKUP#\~/}" ;; esac
if [ "$(wl_cfg backup done)" != yes ]; then
  note "Your agent did not make its own backup (done=no); the installer's undo point above covers the files Setup changes."
elif [ ! -d "$AGENT_BACKUP" ]; then
  note "Your agent reported a backup at $AGENT_BACKUP but that folder was not found on this Mac."
else
  ok "agent backup found: $AGENT_BACKUP ($(wl_cfg backup files) files)"
fi

# --- preflight: a new hub needs Docker; fail before touching anything -------------------------
COMPOSE=""
if [ "$MODE" = new ]; then
  step "Docker (required for a new hub)"
  if ! has docker && [ -d /Applications/Docker.app ]; then
    run open -a Docker
    [ "$DRY" = 1 ] || for _ in $(seq 1 30); do has docker && break; sleep 2; done
  fi
  if ! has docker; then
    fatal "Docker is not installed. Install Docker Desktop for Mac (https://www.docker.com/products/docker-desktop/), start it once, then run Wolf Leader setup again."
  else
    if ! docker info >/dev/null 2>&1; then
      say "  Docker is installed but not running; starting Docker Desktop (can take a minute)..."
      run open -a Docker
      if [ "$DRY" = 0 ]; then
        for _ in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 2; done
      fi
    fi
    if [ "$DRY" = 0 ] && ! docker info >/dev/null 2>&1; then
      fatal "Docker Desktop did not start. Open Docker, wait for it to say it is running, then run Wolf Leader setup again."
    fi
    if docker compose version >/dev/null 2>&1; then
      COMPOSE="docker compose"
    elif has docker-compose; then
      COMPOSE="docker-compose"
    elif [ "$DRY" = 1 ]; then
      COMPOSE="docker compose"
    else
      fatal "Docker Compose is missing. Update Docker Desktop, then run Wolf Leader setup again."
    fi
    ok "docker: $(docker --version 2>/dev/null || echo present)"
  fi
  [ -n "$COMPOSE" ] || COMPOSE="docker compose"
fi

# --- prereqs: git (Command Line Tools) + python ----------------------------------------------
if has_toggle prereqs; then
  step "Git and Python"
  if git_usable; then
    ok "git: $(git --version 2>/dev/null)"
  elif [ "$IS_MAC" = 1 ] && ! clt_ok || [ "$IS_MAC" = 0 ]; then
    run xcode-select --install || true
    warn "Apple's Command Line Tools installer was opened (it provides git). Click Install, wait for it to finish, then run Wolf Leader setup again so git steps complete."
  elif has brew; then
    run brew install git || warn "brew install git failed"
  else
    warn "git is missing and could not be installed automatically"
  fi
  if PY=$(real_python); then
    ok "python: $("$PY" --version 2>&1)"
  elif has brew; then
    run brew install python@3.13 || warn "brew install python@3.13 failed; install Python from https://www.python.org/downloads/macos/"
  else
    run open "https://www.python.org/downloads/macos/" || true
    warn "Python 3 is missing. The python.org download page was opened: install it, then the Wolf Leader skills can upload full transcripts."
  fi
else
  step "Git and Python"
  skip "not selected"
fi

# --- git identity (always) + safe.directory --------------------------------------------------
gitcfg_quote() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

step "Git identity"
if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
  warn "no git name/email given; skipped git config"
elif git_usable; then
  run git config --global user.name "$GIT_NAME" || warn "could not set git user.name"
  run git config --global user.email "$GIT_EMAIL" || warn "could not set git user.email"
  if git config --global --get-all safe.directory 2>/dev/null | grep -Fqx '*'; then
    ok "safe.directory '*' already set"
  else
    run git config --global --add safe.directory '*' || warn "could not set git safe.directory"
  fi
elif [ ! -f "$HOME/.gitconfig" ]; then
  # git itself is not usable yet (Command Line Tools pending); write the same settings directly.
  write_file "$HOME/.gitconfig" 644 <<EOF
[user]
	name = $(gitcfg_quote "$GIT_NAME")
	email = $(gitcfg_quote "$GIT_EMAIL")
[safe]
	directory = *
EOF
else
  warn "git is not usable yet, so git name/email were not set. After Command Line Tools finish, run: git config --global user.name \"$GIT_NAME\"; git config --global user.email \"$GIT_EMAIL\"; git config --global --add safe.directory '*'"
fi

# --- shares: Keychain + mount + Login Items --------------------------------------------------
smb_mount_point() {
  mount 2>/dev/null | LC_ALL=C awk -v h="$1" -v s="$2" '
    / \(smbfs/ {
      src = $1; sub(/^\/\//, "", src)
      at = index(src, "@"); if (at) src = substr(src, at + 1)
      i = index(src, "/"); hs = tolower(substr(src, 1, i - 1)); ss = tolower(substr(src, i + 1))
      gsub(/%20/, " ", ss)
      if (hs == tolower(h) && ss == tolower(s)) {
        mp = $0; sub(/^[^ ]+ on /, "", mp); sub(/ \(smbfs.*$/, "", mp); print mp; exit
      }
    }'
}

url_part() { printf '%s' "$1" | sed 's/%/%25/g; s/ /%20/g; s/@/%40/g; s/:/%3A/g; s/\//%2F/g'; }

sec_quote() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# Store an SMB password in the login Keychain without it ever appearing in argv or the log:
# the command is fed to `security -i` on stdin.
keychain_store() {
  local user=$1 host=$2 pw=$3
  if [ "$DRY" = 1 ]; then
    printf '  [dry-run] security add-internet-password -a %q -s %q -r "smb " -l %q -w <hidden> -U   (sent via stdin to security -i)\n' "$user" "$host" "$host"
    return 0
  fi
  printf 'add-internet-password -a %s -s %s -r "smb " -l %s -w %s -U\n' \
    "$(sec_quote "$user")" "$(sec_quote "$host")" "$(sec_quote "$host")" "$(sec_quote "$pw")" \
    | security -i >/dev/null 2>&1
  if security find-internet-password -a "$user" -s "$host" -r "smb " >/dev/null 2>&1; then
    ok "password for $user@$host saved in your login Keychain"
  else
    warn "could not save the password for $user@$host in Keychain; Finder will ask for it (tick 'Remember this password')"
  fi
}

add_login_item() {
  local mp=$1
  if [ "$DRY" = 1 ]; then
    printf '  [dry-run] osascript: tell application "System Events" to make login item at end with properties {path:%q, hidden:true}\n' "$mp"
    return 0
  fi
  if osascript - "$mp" >/dev/null 2>&1 <<'AS'
on run argv
  set p to item 1 of argv
  tell application "System Events"
    set existing to path of every login item
    if existing does not contain p then make login item at end with properties {path:p, hidden:true}
  end tell
end run
AS
  then
    ok "$mp added to Login Items (re-mounts at login)"
  else
    warn "could not add $mp to Login Items (permission to control System Events was denied?). Add it in System Settings > General > Login Items."
  fi
}

step "Network shares"
if ! has_toggle shares; then
  skip "not selected"
elif [ -z "$SHARES" ]; then
  skip "the answer file lists no shares"
else
  note "macOS may ask to let Wolf Leader control System Events (to add shares to Login Items). Click OK."
  for s in $SHARES; do
    url=$(wl_cfg "$s" smb_url)
    user=$(wl_cfg "$s" user)
    pwmode=$(wl_cfg "$s" password)
    role=$(wl_cfg "$s" role)
    rest=${url#smb://}
    hostpart=${rest%%/*}
    case "$hostpart" in *@*) hostpart=${hostpart#*@} ;; esac
    host=$hostpart
    share=${rest#*/}
    share=${share%/}
    share_plain=$(printf '%s' "$share" | sed 's/%20/ /g')
    share_enc=$(printf '%s' "$share_plain" | sed 's/ /%20/g')
    say "  [$s] smb://$host/$share_plain  user=$user  role=$role"

    if [ "$user" = NONE ]; then
      mount_url="smb://guest:@$host/$share_enc"
    else
      mount_url="smb://$(url_part "$user")@$host/$share_enc"
      if [ "$pwmode" = ASK ]; then
        pwvar="SECRET_$s"
        if [ -n "${!pwvar-}" ]; then
          keychain_store "$user" "$host" "${!pwvar}"
        else
          warn "no password was entered for $user@$host; Finder will ask when it connects"
        fi
        unset "$pwvar"
      fi
    fi

    mp=$(smb_mount_point "$host" "$share_plain")
    if [ -n "$mp" ]; then
      ok "already mounted at $mp"
    else
      run open "$mount_url" || warn "could not open $mount_url"
      if [ "$DRY" = 1 ]; then
        mp="/Volumes/$share_plain"
      else
        for _ in $(seq 1 45); do
          mp=$(smb_mount_point "$host" "$share_plain")
          [ -n "$mp" ] && break
          sleep 2
        done
        if [ -n "$mp" ]; then ok "mounted at $mp"; else warn "smb://$host/$share_plain did not mount within 90 s (Finder may still be asking for a password)"; fi
      fi
    fi
    if [ -n "$mp" ]; then
      add_login_item "$mp"
      [ "$role" = wolf ] && WOLF_MOUNT=$mp
    fi
  done
fi

# --- client: skills + rule + AGENTS.md + MCP + env (no hooks) --------------------------------
merge_mcp_json() {
  local file=$1 url=$2 py
  if [ "$DRY" = 1 ]; then
    say "  [dry-run] merge mcpServers.wolf-leader = {\"url\": \"$url\"} into $file (keeps every other entry; backup first)"
    return 0
  fi
  if [ ! -s "$file" ]; then
    mkdir -p "$(dirname "$file")"
    printf '{\n  "mcpServers": {\n    "wolf-leader": {\n      "url": "%s"\n    }\n  }\n}\n' "$url" >"$file"
    ok "created $file"
    return 0
  fi
  cp -p "$file" "$file.wolf-backup"
  if py=$(real_python); then
    if WL_MCP_URL="$url" "$py" - "$file" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
data = json.loads(text) if text.strip() else {}
if not isinstance(data, dict):
    sys.exit(3)
servers = data.setdefault("mcpServers", {})
if not isinstance(servers, dict):
    sys.exit(3)
servers["wolf-leader"] = {"url": os.environ["WL_MCP_URL"]}
tmp = path + ".wolf-tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
    then
      ok "merged wolf-leader into $file (backup: $file.wolf-backup)"
      return 0
    fi
    cp -p "$file.wolf-backup" "$file"
    warn "$file is not plain JSON, so it was left alone. Add this under \"mcpServers\": \"wolf-leader\": {\"url\": \"$url\"}"
    return 1
  fi
  # No python: plutil edits JSON in place. Anything odd (comments, nulls) makes it fail, and then
  # the original file is restored untouched.
  if has plutil; then
    plutil -extract mcpServers raw "$file" >/dev/null 2>&1 || plutil -insert mcpServers -json '{}' "$file" >/dev/null 2>&1
    if plutil -replace mcpServers.wolf-leader -json "{\"url\":\"$url\"}" "$file" >/dev/null 2>&1 \
      && [ "$(LC_ALL=C tr -d ' \t\r\n' <"$file" | cut -c1)" = "{" ]; then
      ok "merged wolf-leader into $file with plutil (backup: $file.wolf-backup)"
      return 0
    fi
    cp -p "$file.wolf-backup" "$file"
  fi
  warn "could not merge $file without Python. Add this under \"mcpServers\" yourself: \"wolf-leader\": {\"url\": \"$url\"}"
  return 1
}

install_skills() {
  local src=$1 dest=$2 d name
  run mkdir -p "$dest"
  for d in "$src"/*; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    run rm -rf "$dest/$name"
    run cp -R "$d" "$dest/$name"
    run find "$dest/$name" -name __pycache__ -type d -prune -exec rm -rf {} +
    run find "$dest/$name" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +
  done
  run rm -rf "$dest/save-new"
}

step "Cursor / Claude Code client"
if ! has_toggle client; then
  skip "not selected"
else
  EX="$ROOT/examples/cursor"
  if [ ! -d "$EX/skills" ] || [ ! -d "$EX/rules" ]; then
    fatal "client files are missing from this installer ($EX)"
  else
    CURSOR_DIR="$HOME/.cursor"
    install_skills "$EX/skills" "$CURSOR_DIR/skills"
    run mkdir -p "$CURSOR_DIR/rules"
    for f in "$EX"/rules/*.mdc; do
      run cp "$f" "$CURSOR_DIR/rules/"
    done
    if [ -f "$ROOT/examples/AGENTS.md" ]; then
      run cp "$ROOT/examples/AGENTS.md" "$CURSOR_DIR/AGENTS.md"
    fi
    if [ "$(wl_cfg detected claude_code)" = yes ]; then
      install_skills "$EX/skills" "$HOME/.claude/skills"
    else
      skip "Claude Code skills (answer file says claude_code=no)"
    fi
    write_file "$CURSOR_DIR/wolf-leader.env" 644 <<EOF
# Wolf Leader hub URLs (written by Wolf Leader Setup). Edit if your hub moves.
WOLF_LEADER_API=$HUB_URL
WOLF_LEADER_MCP=$MCP_URL
EOF
    merge_mcp_json "$CURSOR_DIR/mcp.json" "$MCP_URL" || true
    skip "hooks (not installed: the rule + MCP do the saving)"
    note "Restart Cursor (and Claude Code) so the Wolf Leader rule, skills and MCP server load."
  fi
fi

# --- obsidian ---------------------------------------------------------------------------------
step "Obsidian"
if [ "$MODE" = new ]; then
  VAULT="$HOME/WolfLeader/share/wolf-leader/vault"
elif [ -n "$WOLF_MOUNT" ]; then
  VAULT="$WOLF_MOUNT/wolf-leader/vault"
else
  VAULT="<your Wolf Leader share>/wolf-leader/vault"
fi
if ! has_toggle obsidian; then
  skip "not selected"
else
  if [ -d /Applications/Obsidian.app ] || [ -d "$HOME/Applications/Obsidian.app" ]; then
    ok "Obsidian is already installed"
  elif has brew; then
    run brew install --cask obsidian || warn "brew could not install Obsidian; get it from https://obsidian.md/download"
  else
    run open "https://obsidian.md/download" || true
    note "The Obsidian download page was opened; drag Obsidian into Applications."
  fi
  note "In Obsidian choose 'Open folder as vault' and pick: $VAULT"
fi

# --- mode=new: run the hub in Docker ---------------------------------------------------------
set_env_key() {
  local file=$1 key=$2 val=$3 shown=${4-}
  [ -n "$shown" ] || shown=$val
  if [ "$DRY" = 1 ]; then
    say "  [dry-run] set $key=$shown in $file"
    return 0
  fi
  WL_K="$key" WL_V="$val" awk '
    BEGIN { k = ENVIRON["WL_K"]; v = ENVIRON["WL_V"] }
    index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$file" >"$file.wolf-tmp" && mv "$file.wolf-tmp" "$file"
}

if [ "$MODE" = new ]; then
  step "Wolf Leader hub (Docker)"
  if [ "$HUB_DIR" = "$ROOT" ]; then
    ok "using this checkout as the hub folder: $HUB_DIR"
  else
    run mkdir -p "$HUB_DIR"
    run rsync -a --exclude .git --exclude node_modules --exclude .next --exclude out --exclude .source \
      --exclude __pycache__ --exclude .env --exclude /data --exclude /installer --exclude .DS_Store \
      "$ROOT/" "$HUB_DIR/" || fatal "could not copy the hub files to $HUB_DIR"
  fi
  PGDATA_DIR="$WL_HOME/pgdata"
  SHARE_DIR="$WL_HOME/share"
  run mkdir -p "$PGDATA_DIR" "$SHARE_DIR/wolf-leader/vault" "$SHARE_DIR/wolf-leader/hub" "$HUB_DIR/data"

  ENV_FILE="$HUB_DIR/.env"
  if [ -f "$ENV_FILE" ]; then
    run cp -p "$ENV_FILE" "$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)"
  else
    run cp "$HUB_DIR/.env.example" "$ENV_FILE" || fatal "missing $HUB_DIR/.env.example"
    if has openssl; then
      PGPW=$(openssl rand -hex 16)
    else
      PGPW=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    fi
    set_env_key "$ENV_FILE" POSTGRES_PASSWORD "$PGPW" "<generated, not shown>"
    unset PGPW
  fi
  if has_toggle wiki; then WIKI=1; else WIKI=0; fi
  set_env_key "$ENV_FILE" IDE_STORAGE_PUBLIC_URL "$HUB_URL"
  set_env_key "$ENV_FILE" IDE_STORAGE_MCP_URL "$MCP_URL"
  set_env_key "$ENV_FILE" WOLF_TZ "$TZ_NAME"
  set_env_key "$ENV_FILE" WOLF_WIKI_ENABLED "$WIKI"
  # Docker Desktop can only bind-mount folders under /Users (and a few others), so the default
  # Linux paths (/srv/wolf, /var/lib/wolf-postgres) are moved into ~/WolfLeader.
  set_env_key "$ENV_FILE" WOLF_SHARE_ROOT "$SHARE_DIR"
  set_env_key "$ENV_FILE" WOLF_PGDATA "$PGDATA_DIR"

  say "  Building and starting the hub. The first build downloads a lot and can take 10-15 minutes."
  # shellcheck disable=SC2086
  if ! run_in "$HUB_DIR" $COMPOSE -f docker-compose.postgres.yml up -d --build; then
    fatal "docker compose failed (see the log above). Fix it, then run Wolf Leader setup again."
  fi

  PORT=$(awk -F= '$1 == "PORT" { print $2 }' "$ENV_FILE" 2>/dev/null | tail -n 1)
  LOCAL_HEALTH="http://localhost:${PORT:-6971}/health"
  if [ "$DRY" = 1 ]; then
    say "  [dry-run] poll $LOCAL_HEALTH every 10 s for up to 10 minutes"
  else
    say "  Waiting for $LOCAL_HEALTH (up to 10 minutes)..."
    up=0
    for i in $(seq 1 60); do
      if curl -fsS --max-time 5 "$LOCAL_HEALTH" >/dev/null 2>&1; then up=1; break; fi
      [ $((i % 6)) -eq 0 ] && say "  ...still starting ($((i / 6)) min)"
      sleep 10
    done
    if [ "$up" = 1 ]; then
      ok "hub is up at $LOCAL_HEALTH"
    else
      warn "the hub did not answer within 10 minutes. Check: (cd \"$HUB_DIR\" && $COMPOSE -f docker-compose.postgres.yml logs wolf-leader)"
    fi
  fi
  note "Hub files: $HUB_DIR  Data: $WL_HOME. Other computers reach this hub at http://$DEVICE.local:6971 (MCP http://$DEVICE.local:6972/mcp)."
fi

# --- final health check ----------------------------------------------------------------------
step "Hub check"
HEALTH_URL="${HUB_URL%/}/health"
result health_url "$HEALTH_URL"
if [ "$DRY" = 1 ]; then
  say "  [dry-run] curl -fsS --max-time 10 $HEALTH_URL"
  result health skipped
elif BODY=$(curl -fsS --max-time 10 "$HEALTH_URL" 2>&1); then
  ok "$HEALTH_URL answered: $(printf '%s' "$BODY" | tr '\n' ' ' | cut -c1-200)"
  result health ok
  result health_body "$BODY"
else
  warn "$HEALTH_URL did not answer ($BODY). Is the hub running and is this Mac on the same network?"
  result health fail
  result health_body "$BODY"
fi

finish ok
say ""
if [ "$WARNINGS" -gt 0 ]; then
  say "Finished with $WARNINGS warning(s); see WARN lines above. Log: $LOG"
else
  say "Finished. Log: $LOG"
fi
exit 0
