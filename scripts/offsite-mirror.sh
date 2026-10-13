#!/usr/bin/env bash
# Keep a copy of a Wolf Leader hub's git repos and newest database dump on another machine.
#
# Runs on the machine that holds the copy (a laptop, a NAS) and pulls over SSH, so the hub
# server needs no credentials for anywhere else. Reports each run to the hub, which shows
# "last off-site copy" in the app.
#
#   offsite-mirror.sh --host SSH_NAME            copy now
#   offsite-mirror.sh --install --host SSH_NAME  copy now, then every day (launchd on macOS, cron elsewhere)
#   offsite-mirror.sh --uninstall                stop the daily run (copies are kept)
#
# Options (or the matching environment variable):
#   --host NAME        SSH name of the hub server                      WOLF_SSH_HOST
#   --dest DIR         where to keep the copy   [~/WolfLeaderBackup]    WOLF_OFFSITE_DEST
#   --git-dir DIR      repos on the server      [/srv/content/wolf-leader/git]   WOLF_REMOTE_GIT_DIR
#   --dump-dir DIR     dumps on the server      [/srv/content/wolf-leader/hub]   WOLF_REMOTE_DUMP_DIR
#   --api URL          hub API to report to     [from wolf-leader.env] WOLF_LEADER_API
#   --keep N           database dumps to keep   [14]                   WOLF_OFFSITE_KEEP
set -uo pipefail

for env_file in "$HOME/.claude/wolf-leader.env" "$HOME/.codex/wolf-leader.env" "$HOME/.cursor/wolf-leader.env"; do
  # shellcheck disable=SC1090
  [[ -f "$env_file" ]] && source "$env_file"
done
CONFIG="$HOME/.config/wolf-leader/offsite-mirror.env"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"

HOST="${WOLF_SSH_HOST:-}"
DEST="${WOLF_OFFSITE_DEST:-$HOME/WolfLeaderBackup}"
GIT_DIR="${WOLF_REMOTE_GIT_DIR:-/srv/content/wolf-leader/git}"
DUMP_DIR="${WOLF_REMOTE_DUMP_DIR:-/srv/content/wolf-leader/hub}"
API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
KEEP="${WOLF_OFFSITE_KEEP:-14}"
MODE=run
LABEL=app.wolfleader.offsite-mirror
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) MODE=install; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --dest) DEST="${2:-}"; shift 2 ;;
    --git-dir) GIT_DIR="${2:-}"; shift 2 ;;
    --dump-dir) DUMP_DIR="${2:-}"; shift 2 ;;
    --api) API="${2:-}"; shift 2 ;;
    --keep) KEEP="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "offsite-mirror: unknown option $1" >&2; exit 2 ;;
  esac
done
API="${API%/}"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

if [[ "$MODE" == uninstall ]]; then
  if [[ -f "$PLIST" ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
  fi
  if command -v crontab >/dev/null 2>&1; then
    crontab -l 2>/dev/null | grep -v "wolf-leader-offsite-mirror" | crontab - 2>/dev/null || true
  fi
  echo "Daily off-site copy stopped. Existing copies in $DEST were kept."
  exit 0
fi

if [[ -z "$HOST" ]]; then
  echo "offsite-mirror: say which server to copy from: --host SSH_NAME (the name you use with ssh)" >&2
  exit 2
fi

report() {  # ok(true|false) repos dump bytes detail
  local device; device="$(hostname | sed 's/"/_/g')"
  local detail="${5//\\/\\\\}"; detail="${detail//\"/\\\"}"
  curl -fsS -m 20 -X POST "$API/api/backups/offsite" -H 'Content-Type: application/json' \
    -d "{\"ok\":$1,\"repos\":$2,\"dump_name\":\"$3\",\"bytes\":$4,\"device_name\":\"$device\",\"destination\":\"$DEST\",\"detail\":\"${detail:0:900}\"}" \
    >/dev/null 2>&1 || echo "offsite-mirror: copied, but could not report to the hub at $API" >&2
}

run_copy() {
  mkdir -p "$DEST/git" "$DEST/db" || { echo "offsite-mirror: cannot write to $DEST" >&2; return 1; }
  local log="$DEST/last-run.log" out
  : >"$log"
  # Bare repos are plain files: an exact mirror is a full, restorable copy of every project's history.
  if ! out=$(rsync -a --delete -e "ssh -o BatchMode=yes -o ConnectTimeout=20" "$HOST:$GIT_DIR/" "$DEST/git/" 2>&1); then
    echo "$out" >>"$log"
    report false 0 "" 0 "git copy failed: $out"
    echo "offsite-mirror: copying repos from $HOST failed: $out" >&2
    return 1
  fi
  local newest
  newest=$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$HOST" "ls -t '$DUMP_DIR'/wolf-leader-*.dump 2>/dev/null | head -n 1" 2>>"$log")
  local dump_name=""
  if [[ -n "$newest" ]]; then
    dump_name="$(basename "$newest")"
    if ! out=$(rsync -a -e "ssh -o BatchMode=yes -o ConnectTimeout=20" "$HOST:$newest" "$DEST/db/" 2>&1); then
      echo "$out" >>"$log"
      report false 0 "$dump_name" 0 "database dump copy failed: $out"
      echo "offsite-mirror: copying $dump_name failed: $out" >&2
      return 1
    fi
    # Keep the newest $KEEP dumps here; the server keeps its own set.
    ls -t "$DEST"/db/wolf-leader-*.dump 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do rm -f "$old"; done
  fi
  local repos bytes
  repos=$(find "$DEST/git" -maxdepth 1 -type d -name '*.git' | wc -l | tr -d ' ')
  bytes=$(du -sk "$DEST" 2>/dev/null | awk '{print $1 * 1024}')
  date -u +%FT%TZ >"$DEST/last-success"
  report true "$repos" "$dump_name" "${bytes:-0}" ""
  echo "Copied $repos repo(s)${dump_name:+ and $dump_name} from $HOST to $DEST"
}

if [[ "$MODE" == run ]]; then
  run_copy
  exit $?
fi

# --- install: remember the settings, copy once, then schedule a daily run ------------------
mkdir -p "$(dirname "$CONFIG")"
cat >"$CONFIG" <<CONF
# Written by offsite-mirror.sh --install. Edit to change where the copy comes from or goes.
WOLF_SSH_HOST="$HOST"
WOLF_OFFSITE_DEST="$DEST"
WOLF_REMOTE_GIT_DIR="$GIT_DIR"
WOLF_REMOTE_DUMP_DIR="$DUMP_DIR"
WOLF_LEADER_API="$API"
WOLF_OFFSITE_KEEP="$KEEP"
CONF
INSTALLED="$HOME/.config/wolf-leader/wolf-leader-offsite-mirror.sh"
[[ "$SELF" != "$INSTALLED" ]] && cp "$SELF" "$INSTALLED"
chmod +x "$INSTALLED"

run_copy || { echo "offsite-mirror: the first copy failed, so nothing was scheduled." >&2; exit 1; }

if [[ "$(uname)" == Darwin ]]; then
  mkdir -p "$(dirname "$PLIST")"
  cat >"$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>/bin/bash</string><string>$INSTALLED</string></array>
	<key>StartCalendarInterval</key>
	<dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>30</integer></dict>
	<key>StandardOutPath</key><string>$DEST/launchd.log</string>
	<key>StandardErrorPath</key><string>$DEST/launchd.log</string>
</dict>
</plist>
PL
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" || { echo "offsite-mirror: could not schedule the daily run" >&2; exit 1; }
  echo "Scheduled: daily at 12:30 (and at next wake if the Mac was asleep). Stop with: bash $INSTALLED --uninstall"
else
  ( crontab -l 2>/dev/null | grep -v "wolf-leader-offsite-mirror"; echo "30 12 * * * /bin/bash $INSTALLED >> $DEST/cron.log 2>&1" ) | crontab -
  echo "Scheduled: daily at 12:30 via cron. Stop with: bash $INSTALLED --uninstall"
fi
