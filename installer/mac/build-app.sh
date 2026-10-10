#!/bin/bash
# Build the Wolf Leader Mac app and its drag-to-install disk image. Run on a Mac with Xcode or the
# Command Line Tools, from anywhere:
#
#   bash installer/mac/build-app.sh [version] [--app-only]
#
# Produces:
#   dist/Wolf Leader.app            SwiftUI app (universal when possible) with the setup payload
#   dist/WolfLeader-<ver>.dmg       classic "drag Wolf Leader to Applications" image (skipped with --app-only)
#
# The app is ad-hoc signed only (no Apple Developer ID), so the first launch is blocked by Gatekeeper:
#   macOS 14: right-click the app > Open > Open.
#   macOS 15 and newer: double-click once, then System Settings > Privacy & Security > "Open Anyway".
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

if [ "$(uname -s)" != Darwin ]; then
  echo "build-app.sh must run on macOS (it needs swift, sips, iconutil, codesign and hdiutil)." >&2
  exit 1
fi
if ! command -v swift >/dev/null 2>&1 || ! xcode-select -p >/dev/null 2>&1; then
  echo "Swift is missing. Install Xcode from the App Store, or run: xcode-select --install" >&2
  exit 1
fi

VERSION=""
APP_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --app-only) APP_ONLY=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *) VERSION=$arg ;;
  esac
done

# --- version + git facts for Info.plist -------------------------------------------------------
clean_version() { printf '%s' "$1" | sed 's/^[vV]//' | grep -E '^[0-9]+(\.[0-9]+){0,2}$' || true; }

[ -n "$VERSION" ] || VERSION=${WL_VERSION:-}
[ -n "$VERSION" ] || VERSION=$(clean_version "$(git describe --tags --abbrev=0 2>/dev/null || true)")
[ -n "$VERSION" ] || VERSION=$(sed -n 's/.*FastAPI(.*version="\([0-9][0-9.]*\)".*/\1/p' ide_storage/main.py 2>/dev/null | head -n 1)
[ -n "$VERSION" ] || VERSION=$(date +%Y.%m.%d)
SHORT_VERSION=$(clean_version "$VERSION")
[ -n "$SHORT_VERSION" ] || SHORT_VERSION="0.0.0"
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)

GIT_SHA=$(git rev-parse HEAD 2>/dev/null || true)
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
[ "$GIT_BRANCH" != HEAD ] || GIT_BRANCH=""

# git@github.com:owner/repo.git, ssh://git@host/owner/repo, https://user@host/owner/repo.git
#   -> https://host/owner/repo. Anything else (a file path on a share) prints nothing.
normalize_repo() {
  local u=$1 rest="" host="" path=""
  u=${u%/}
  u=${u%.git}
  case "$u" in
    git@*:*)
      host=${u#git@}
      host=${host%%:*}
      path=${u#*:}
      ;;
    ssh://*|http://*|https://*)
      rest=${u#*://}
      case "$rest" in */*) ;; *) return 0 ;; esac
      host=${rest%%/*}
      path=${rest#*/}
      case "$host" in *@*) host=${host#*@} ;; esac
      host=${host%%:*}
      ;;
    *) return 0 ;;
  esac
  [ -n "$host" ] && [ -n "$path" ] || return 0
  printf 'https://%s/%s' "$host" "$path"
}

REPO_URL=${WL_REPO_URL:-}
if [ -z "$REPO_URL" ]; then
  REPO_URL=$(normalize_repo "$(git remote get-url origin 2>/dev/null || true)")
fi
if [ -z "$REPO_URL" ]; then
  # origin is often a bare repo on the share; use whichever remote points at GitHub instead.
  for r in $(git remote 2>/dev/null || true); do
    u=$(git remote get-url "$r" 2>/dev/null || true)
    case "$u" in *github.com*) REPO_URL=$(normalize_repo "$u"); break ;; esac
  done
fi

PKG="$ROOT/installer/mac/WolfLeaderApp"
ASSETS="$ROOT/installer/assets"
DIST="$ROOT/dist"
APP="$DIST/Wolf Leader.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
PAY="$RES/payload"
DMG="$DIST/WolfLeader-$VERSION.dmg"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wl-build-app.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

echo "Building Wolf Leader $VERSION (${GIT_BRANCH:-no branch} ${GIT_SHA:0:7})"
[ -n "$REPO_URL" ] && echo "  repo: $REPO_URL" || echo "  note: no GitHub remote found; update checks stay off (set WL_REPO_URL to override)"
mkdir -p "$DIST"

# --- 1. compile ---------------------------------------------------------------------------------
echo "==> Compiling (release)"
if swift build -c release --arch arm64 --arch x86_64 --package-path "$PKG"; then
  BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --package-path "$PKG" --show-bin-path)
  echo "  universal binary (Apple silicon + Intel)"
else
  echo "  note: universal build failed; building for this Mac's architecture only"
  swift build -c release --package-path "$PKG"
  BIN_DIR=$(swift build -c release --package-path "$PKG" --show-bin-path)
fi
BIN="$BIN_DIR/WolfLeader"
[ -x "$BIN" ] || { echo "Build finished but $BIN is missing." >&2; exit 1; }

# --- 2. the .app bundle -------------------------------------------------------------------------
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$RES"
cp "$BIN" "$CONTENTS/MacOS/WolfLeader"
for b in "$BIN_DIR"/*.bundle; do
  if [ -d "$b" ]; then cp -R "$b" "$RES/"; fi
done

xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

cat >"$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>WolfLeader</string>
	<key>CFBundleIdentifier</key>
	<string>app.wolfleader.mac</string>
	<key>CFBundleName</key>
	<string>Wolf Leader</string>
	<key>CFBundleDisplayName</key>
	<string>Wolf Leader</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleShortVersionString</key>
	<string>$(xml_escape "$SHORT_VERSION")</string>
	<key>CFBundleVersion</key>
	<string>$(xml_escape "$BUILD_NUMBER")</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>Wolf Leader adds your network shares to Login Items so they reconnect when you log in.</string>
	<key>WLGitSHA</key>
	<string>$(xml_escape "$GIT_SHA")</string>
	<key>WLGitBranch</key>
	<string>$(xml_escape "$GIT_BRANCH")</string>
	<key>WLRepoURL</key>
	<string>$(xml_escape "$REPO_URL")</string>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null
printf 'APPL????' >"$CONTENTS/PkgInfo"

# --- 3. icon: .iconset from app-icon.png, then iconutil ----------------------------------------
echo "==> App icon"
ICON_SRC="$ASSETS/app-icon.png"
make_icon() {
  local set="$TMP/AppIcon.iconset" s d
  [ -f "$ICON_SRC" ] || return 1
  mkdir -p "$set"
  for s in 16 32 128 256 512; do
    d=$((s * 2))
    sips -s format png -z "$s" "$s" "$ICON_SRC" --out "$set/icon_${s}x${s}.png" >/dev/null || return 1
    sips -s format png -z "$d" "$d" "$ICON_SRC" --out "$set/icon_${s}x${s}@2x.png" >/dev/null || return 1
  done
  iconutil -c icns "$set" -o "$RES/AppIcon.icns" || return 1
}
if make_icon; then
  echo "  AppIcon.icns from ${ICON_SRC#"$ROOT"/}"
else
  echo "  WARN: could not build AppIcon.icns from ${ICON_SRC#"$ROOT"/}; the app will have a blank icon"
fi

# --- 4. payload: what first-launch setup and a new hub need ------------------------------------
echo "==> Payload"
EXCL=(--exclude __pycache__ --exclude '*.pyc' --exclude .DS_Store)
mkdir -p "$PAY/installer/mac"
cp installer/mac/install.sh installer/mac/ini.sh "$PAY/installer/mac/"
cp installer/PROMPT.md installer/CONFIG.md "$PAY/installer/"
rsync -a "${EXCL[@]}" examples scripts ide_storage "$PAY/"
rsync -a "${EXCL[@]}" --exclude node_modules --exclude .next --exclude out --exclude .source \
  --exclude next-env.d.ts --exclude '*.tsbuildinfo' wiki "$PAY/"
for f in Dockerfile .dockerignore docker-compose*.yml requirements*.txt .env.example start.sh; do
  if [ -e "$f" ]; then cp "$f" "$PAY/"; fi
done
# A Windows checkout may have CRLF scripts; bash on the Mac needs LF.
find "$PAY" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.command' \) -print0 | xargs -0 perl -pi -e 's/\r$//'
find "$PAY" -type f -name '*.sh' -print0 | xargs -0 chmod +x
echo "  $(du -sh "$PAY" | cut -f1) in Contents/Resources/payload"

# --- 5. sign (ad-hoc) ---------------------------------------------------------------------------
echo "==> Signing (ad-hoc)"
xattr -cr "$APP"
codesign --force --deep -s - "$APP"
codesign --verify --deep "$APP"
echo "  app: $APP"

if [ "$APP_ONLY" = 1 ]; then
  echo "Done (app only)."
  exit 0
fi

# --- 6. disk image: drag Wolf Leader to Applications -------------------------------------------
echo "==> Disk image"
STAGE="$TMP/stage"
RW="$TMP/rw.dmg"
WIN_W=600
WIN_H=380
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Wolf Leader.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"

finder_layout_script() {
  cat <<'AS'
on run argv
  set volName to item 1 of argv
  set winW to (item 2 of argv) as integer
  set winH to (item 3 of argv) as integer
  tell application "Finder"
    tell disk volName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 120, 200 + winW, 120 + winH}
      set opts to the icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 128
      set text size of opts to 13
      set background picture of opts to file ".background:background.tiff"
      set position of item "Wolf Leader.app" of container window to {150, 190}
      set position of item "Applications" of container window to {450, 190}
      close
      open
      update without registering applications
      delay 2
      close
    end tell
  end tell
end run
AS
}

# Retina background + Finder layout on a read-write image. Needs Terminal to be allowed to control
# Finder; any failure falls back to a plain image with the same two items.
fancy_dmg() {
  local out dev mnt vol size
  [ -f "$ASSETS/dmg-drag.png" ] && [ -f "$ASSETS/dmg-drag@2x.png" ] || return 1
  mkdir -p "$STAGE/.background"
  tiffutil -cathidpicheck "$ASSETS/dmg-drag.png" "$ASSETS/dmg-drag@2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null 2>&1 || return 1
  size=$(( $(du -sm "$STAGE" | cut -f1) + 40 ))
  hdiutil create -volname "Wolf Leader" -srcfolder "$STAGE" -ov -fs HFS+ -format UDRW \
    -size "${size}m" "$RW" >/dev/null || return 1
  out=$(hdiutil attach -readwrite -noverify -noautoopen "$RW") || return 1
  dev=$(printf '%s\n' "$out" | awk '/\/Volumes\// { print $1; exit }')
  mnt=$(printf '%s\n' "$out" | awk -F'\t' '/\/Volumes\// { print $NF; exit }')
  vol=$(basename "$mnt")
  if ! osascript - "$vol" "$WIN_W" "$WIN_H" <<<"$(finder_layout_script)"; then
    hdiutil detach "$dev" -force >/dev/null 2>&1 || true
    return 1
  fi
  chmod -Rf go-w "$mnt" || true
  sync
  hdiutil detach "$dev" >/dev/null 2>&1 || { sleep 2; hdiutil detach "$dev" -force >/dev/null 2>&1; } || return 1
  hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null || return 1
}

if fancy_dmg; then
  echo "  drag-to-install layout with background"
else
  echo "  note: Finder layout step failed (allow Terminal to control Finder in System Settings >"
  echo "        Privacy & Security > Automation for the full look); building a plain image"
  rm -rf "$STAGE/.background" "$DMG"
  hdiutil create -volname "Wolf Leader" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
fi

echo ""
echo "Done."
echo "  $DMG"
