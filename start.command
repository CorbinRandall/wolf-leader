#!/bin/bash
# Mac: double-click after cloning Wolf Leader. Builds the app (first time only) and opens it;
# setup runs inside the app.
# If macOS says it "cannot be opened": right-click > Open, or run  chmod +x start.command
cd "$(dirname "$0")" || exit 1
APP="dist/Wolf Leader.app"
if [ ! -d "$APP" ] || [ "${1-}" = "--rebuild" ]; then
  echo "Building Wolf Leader (first run takes a minute or two)..."
  if ! /bin/bash installer/mac/build-app.sh; then
    echo ""
    echo "Build failed. Needs macOS 14+ with Xcode or the Command Line Tools (xcode-select --install)."
    exit 1
  fi
fi
open "$APP"
