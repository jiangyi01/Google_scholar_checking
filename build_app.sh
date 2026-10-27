#!/bin/bash
# Build ScholarBar.app without Xcode (SPM + manual bundling + ad-hoc codesign).
# Usage: ./build_app.sh [--run]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP_DIR="$HOME/Applications/ScholarBar.app"
mkdir -p "$HOME/Applications"

# Quit a running instance before replacing the bundle
pkill -x ScholarBar 2>/dev/null || true
sleep 0.3

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/ScholarBar "$APP_DIR/Contents/MacOS/"
cp Resources/Info.plist "$APP_DIR/Contents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/"

codesign --force --sign - --identifier com.yijiang.scholarbar "$APP_DIR"

# Refresh LaunchServices so Finder/Dock pick up the icon
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true

echo "Built: $APP_DIR"
if [ "${1:-}" = "--run" ]; then
    open "$APP_DIR"
    echo "Launched."
fi
