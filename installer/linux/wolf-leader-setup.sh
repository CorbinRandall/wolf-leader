#!/usr/bin/env bash
# Wolf Leader setup for Linux: the terminal version of the Mac app's first-launch setup and the
# Windows wizard. It asks the same questions, then runs the shared installer (installer/mac/install.sh).
#
#   ./wolf-leader-setup                       step by step, in the terminal
#   ./wolf-leader-setup --ini FILE --mode connect|new|update [--toggles client,shares,prereqs,obsidian,wiki]
#                       [--git-name "Name" --git-email you@example.com] [--yes] [--dry-run]
#
# With --ini and --yes nothing is asked (for scripts and tests). Share passwords are only ever read
# from the terminal (hidden) and passed to the installer in a private file it deletes at once.
set -euo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
INSTALL="$ROOT/installer/mac/install.sh"
# shellcheck source=../mac/ini.sh
. "$ROOT/installer/mac/ini.sh"

INI="" MODE="" TOGGLES="" GIT_NAME="" GIT_EMAIL="" YES=0 DRY=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ini) INI=$2; shift 2 ;;
    --mode) MODE=$2; shift 2 ;;
    --toggles) TOGGLES=$2; shift 2 ;;
    --git-name) GIT_NAME=$2; shift 2 ;;
    --git-email) GIT_EMAIL=$2; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY=(--dry-run); shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ask() {  # ask "Question" default -> answer
  local reply
  if [ "$YES" = 1 ]; then printf '%s' "$2"; return; fi
  read -r -p "$1 " reply </dev/tty || true
  printf '%s' "${reply:-$2}"
}
yes_no() {  # yes_no "Question" y|n -> 0 for yes
  local d=$2 r
  r=$(ask "$1 [$( [ "$d" = y ] && echo Y/n || echo y/N )]" "$d")
  case "$r" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

copy_to_clipboard() {
  if command -v wl-copy >/dev/null 2>&1; then wl-copy <"$1" && return 0; fi
  if command -v xclip >/dev/null 2>&1; then xclip -selection clipboard <"$1" && return 0; fi
  if command -v xsel >/dev/null 2>&1; then xsel --clipboard --input <"$1" && return 0; fi
  return 1
}

bold "Wolf Leader setup for Linux"
echo "Wolf Leader keeps your projects and AI chats in one place, for every AI tool you use."
echo

# 1. What kind of install
if [ -z "$MODE" ]; then
  echo "  1) Connect this computer to my Wolf Leader hub"
  echo "  2) Start a new hub on this computer (needs Docker)"
  echo "  3) Update an existing setup"
  case "$(ask "Choose 1, 2 or 3:" 1)" in 2) MODE=new ;; 3) MODE=update ;; *) MODE=connect ;; esac
fi
case "$MODE" in new|connect|update) ;; *) echo "--mode must be new, connect or update" >&2; exit 2 ;; esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/wolf-leader-setup.XXXXXX")
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# 2. The answer file: your own AI agent inspects this computer and writes it
if [ -z "$INI" ]; then
  hint=$([ "$MODE" = new ] && echo "http://localhost:6971" || echo "http://wolf.local:6971")
  awk 'BEGIN{n=0} /^---[ \t]*$/{n++; next} n==1{print}' "$ROOT/installer/PROMPT.md" \
    | sed -e "s|{{OS}}|linux|g" -e "s|{{MODE}}|$MODE|g" -e "s|{{HUB_HINT}}|$hint|g" >"$WORK/prompt.txt"
  cp "$WORK/prompt.txt" "$HOME/wolf-leader-setup-prompt.txt"
  echo
  bold "Step 1: ask your AI agent about this computer"
  if copy_to_clipboard "$WORK/prompt.txt"; then
    echo "The setup prompt is on your clipboard (also saved to ~/wolf-leader-setup-prompt.txt)."
  else
    echo "The setup prompt is saved to ~/wolf-leader-setup-prompt.txt."
  fi
  echo "Paste it into Claude Code, Codex, Cursor or another agent that can run commands here."
  echo "It answers with one INI block."
  echo
  bold "Step 2: paste the agent's answer below, then press Ctrl-D on an empty line"
  while :; do
    cat </dev/tty >"$WORK/answer.ini" || true
    wl_ini_extract "$WORK/answer.ini" >"$WORK/answers.ini"
    if wl_ini_parse "$WORK/answers.ini" linux >"$WORK/cfg"; then break; fi
    echo
    echo "That answer has a problem:"
    sed 's/^/  /' "$WORK/cfg"
    echo "Ask your agent to fix it, then paste the new answer and press Ctrl-D."
  done
  INI="$WORK/answer.ini"
else
  wl_ini_extract "$INI" >"$WORK/answers.ini"
  if ! wl_ini_parse "$WORK/answers.ini" linux >"$WORK/cfg"; then
    echo "The answer file is not valid:" >&2
    sed 's/^/  /' "$WORK/cfg" >&2
    exit 2
  fi
fi
wl_cfg_load "$WORK/cfg"
echo "  hub: $(wl_cfg wolf hub_url)"

# 3. What to set up
if [ -z "$TOGGLES" ]; then
  t=()
  yes_no "Connect your AI tools (Claude Code, Cursor) to Wolf Leader?" y && t+=(client)
  [ -n "$(wl_cfg meta shares)" ] && yes_no "Connect the network share your agent found?" y && t+=(shares)
  yes_no "Install git and Python if they are missing (may ask for your password)?" y && t+=(prereqs)
  yes_no "Install Obsidian, to read your notes as a vault?" n && t+=(obsidian)
  [ "$MODE" = new ] && yes_no "Turn on the built-in wiki?" y && t+=(wiki)
  TOGGLES=$(IFS=,; echo "${t[*]:-}")
fi

# 4. Git identity, used for the commits Wolf Leader notes
[ -n "$GIT_NAME" ] || GIT_NAME=$(git config --global user.name 2>/dev/null || true)
[ -n "$GIT_EMAIL" ] || GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)
if [ "$YES" = 0 ]; then
  GIT_NAME=$(ask "Your name for git [${GIT_NAME:-none}]:" "$GIT_NAME")
  GIT_EMAIL=$(ask "Your email for git [${GIT_EMAIL:-none}]:" "$GIT_EMAIL")
fi

# 5. Share passwords: typed here, hidden, never on a command line or in the log
SECRETS=""
case ",$TOGGLES," in *,shares,*)
  for s in $(wl_cfg meta shares); do
    if [ "$(wl_cfg "$s" password)" = ASK ] && [ "$YES" = 0 ]; then
      read -r -s -p "Password for $(wl_cfg "$s" user) on $(wl_cfg "$s" smb_url): " pw </dev/tty; echo
      SECRETS="$WORK/secrets"
      (umask 077; printf '%s=%s\n' "$s" "$pw" >>"$SECRETS")
      unset pw
    fi
  done ;;
esac

echo
bold "Installing"
args=(--ini "$INI" --mode "$MODE" --toggles "$TOGGLES" --result "$WORK/result.ini" "${DRY[@]}")
[ -n "$GIT_NAME" ] && args+=(--git-name "$GIT_NAME")
[ -n "$GIT_EMAIL" ] && args+=(--git-email "$GIT_EMAIL")
set +e
WL_SECRETS_FILE="$SECRETS" bash "$INSTALL" "${args[@]}"
code=$?
set -e
echo
if [ "$code" = 0 ]; then
  bold "Wolf Leader is set up."
  echo "Open it from your app menu (Wolf Leader), or at $(wl_cfg wolf hub_url)."
  echo "Restart Claude Code and Cursor so they pick up Wolf Leader."
else
  bold "Setup stopped. See the FAIL line above; the log is in ~/.local/state/wolf-leader/install.log."
fi
exit "$code"
