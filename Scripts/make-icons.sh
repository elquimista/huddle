#!/bin/bash
# Regenerates Resources/AppIcon.icns and Resources/AppIcon-Dev.icns from Scripts/make-icon.swift.
# ICON_PREVIEW_DIR=<folder> also saves 1024px PNG previews there.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift Scripts/make-icon.swift "$WORK/AppIcon.iconset"
swift Scripts/make-icon.swift "$WORK/AppIcon-Dev.iconset" --dev
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
iconutil -c icns "$WORK/AppIcon-Dev.iconset" -o Resources/AppIcon-Dev.icns
if [ -n "${ICON_PREVIEW_DIR:-}" ]; then
  cp "$WORK/AppIcon.iconset/icon_512x512@2x.png" "$ICON_PREVIEW_DIR/AppIcon.png"
  cp "$WORK/AppIcon-Dev.iconset/icon_512x512@2x.png" "$ICON_PREVIEW_DIR/AppIcon-Dev.png"
fi
echo "Wrote Resources/AppIcon.icns and Resources/AppIcon-Dev.icns"
