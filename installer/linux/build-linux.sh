#!/usr/bin/env bash
# Build the Linux download: dist/WolfLeader-linux-<version>.tar.gz. Runs anywhere with bash, tar
# and rsync (Linux or a Mac).
#
#   bash installer/linux/build-linux.sh [version]
#
# Inside is one folder, wolf-leader/, holding the same files the Mac app carries, with the setup
# command at the top:  tar xzf WolfLeader-linux-<ver>.tar.gz && ./wolf-leader/wolf-leader-setup
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
VERSION=${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/wolf-leader-linux.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
PAY="$STAGE/wolf-leader"
EXCL=(--exclude __pycache__ --exclude '*.pyc' --exclude .DS_Store)

mkdir -p "$PAY/installer/mac" "$PAY/installer/linux" "$PAY/installer/assets"
cp installer/mac/install.sh installer/mac/ini.sh "$PAY/installer/mac/"
cp installer/linux/wolf-leader-setup.sh "$PAY/installer/linux/"
cp installer/PROMPT.md installer/CONFIG.md "$PAY/installer/"
cp installer/assets/app-icon.png "$PAY/installer/assets/"
rsync -a "${EXCL[@]}" examples scripts ide_storage "$PAY/"
rsync -a "${EXCL[@]}" --exclude node_modules --exclude .next --exclude out --exclude .source \
  --exclude next-env.d.ts --exclude '*.tsbuildinfo' wiki "$PAY/"
for f in Dockerfile .dockerignore docker-compose*.yml requirements*.txt .env.example start.sh LICENSE README.md; do
  if [ -e "$f" ]; then cp "$f" "$PAY/"; fi
done
# A checkout made on Windows may have CRLF scripts; Linux needs LF.
find "$PAY" -type f \( -name '*.sh' -o -name '*.py' \) -print0 | xargs -0 perl -pi -e 's/\r$//'
find "$PAY" -type f -name '*.sh' -print0 | xargs -0 chmod +x
ln -s installer/linux/wolf-leader-setup.sh "$PAY/wolf-leader-setup"
printf '%s\n' "$VERSION" >"$PAY/VERSION"

mkdir -p dist
OUT="dist/WolfLeader-linux-$VERSION.tar.gz"
# Same owner and order every time, so the archive does not depend on who built it.
# On a Mac, keep Apple's file metadata out (Linux tar warns about it).
if tar --version 2>/dev/null | grep -q bsdtar; then
  COPYFILE_DISABLE=1 tar -C "$STAGE" --no-mac-metadata --no-xattrs --uid 0 --gid 0 -czf "$OUT" wolf-leader
else
  tar -C "$STAGE" --owner=0 --group=0 --no-xattrs -czf "$OUT" wolf-leader
fi
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
