#!/bin/bash
#
# Fork addition: builds this fork and swaps it in for /Applications/CodeStatus.app.
#
# The build is ad-hoc signed, which has two consequences worth knowing:
# - The updater refuses to run (see UpdateCoordinator.start), so upstream
#   releases never overwrite the fork. Pull upstream and rerun this instead.
# - macOS sees a different signature, so it asks again for the Automation
#   permission the first time a Terminal row is clicked.
#
# The app being replaced is kept in dist/CodeStatus-previous.app, so going back
# is a matter of moving it into /Applications again.
#
# Usage: scripts/install-local.sh

set -euo pipefail

cd "$(dirname "$0")/.."

APP="dist/CodeStatus.app"
TARGET="/Applications/CodeStatus.app"
BACKUP="dist/CodeStatus-previous.app"

# The bundle version follows the upstream release this branch is based on.
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
export VERSION="${VERSION:-0.0.0}"

scripts/build-app.sh --sign

if pgrep -xq CodeStatusApp; then
    echo "==> Quitting the running CodeStatus"
    osascript -e 'tell application id "co.codestatus.CodeStatus" to quit' || true
    for _ in {1..50}; do pgrep -xq CodeStatusApp || break; sleep 0.1; done
    pkill -x CodeStatusApp || true
fi

if [[ -d "$TARGET" ]]; then
    echo "==> Keeping the current app as $BACKUP"
    rm -rf "$BACKUP"
    mv "$TARGET" "$BACKUP"
fi

echo "==> Installing $TARGET ($VERSION, fork build)"
ditto "$APP" "$TARGET"
open "$TARGET"
