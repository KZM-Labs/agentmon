#!/usr/bin/env bash
# Build Agentmon as a .app bundle.
# Usage: ./build.sh           # release build, outputs ./build/Agentmon.app
#        ./build.sh --debug   # debug build
#        ./build.sh --run     # build + launch

set -euo pipefail

cd "$(dirname "$0")"

MODE="release"
RUN=0
for arg in "$@"; do
    case "$arg" in
        --debug) MODE="debug" ;;
        --run)   RUN=1 ;;
    esac
done

echo "==> Building Agentmon ($MODE)..."
swift build -c "$MODE"

BIN="$(swift build -c "$MODE" --show-bin-path)/Agentmon"
APP="build/Agentmon.app"

echo "==> Assembling .app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Agentmon"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so Gatekeeper doesn't kill it on first launch
codesign --force --sign - "$APP" 2>/dev/null || true

echo "==> Built: $APP"

if [ "$RUN" -eq 1 ]; then
    # Kill any running instance
    pkill -x Agentmon 2>/dev/null || true
    sleep 0.3
    open "$APP"
    echo "==> Launched."
fi
