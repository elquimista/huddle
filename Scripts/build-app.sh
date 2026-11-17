#!/bin/bash
# Builds the app into ./build without Xcode.
#   Scripts/build-app.sh          # release -> build/Huddle.app
#   Scripts/build-app.sh debug    # debug   -> build/Huddle Dev.app (own bundle ID, data folder, Keychain item, icon)
#   HUDDLE_VERSION=1.2.0 Scripts/build-app.sh   # stamps that version (the release workflow passes the
#                                               # tag; without it, the latest v-tag's, else 0.1.0)
# Icons come from Resources/*.icns; regenerate them with Scripts/make-icons.sh.
# Signing: an "Apple Development" certificate if one is in your keychain (Keychain access then
# survives rebuilds), otherwise ad hoc. HUDDLE_SIGN_IDENTITY overrides.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
if [ "$CONFIG" = "debug" ]; then
  NAME="Huddle Dev"; BUNDLE_ID="app.huddle.Huddle.dev"; ICON="AppIcon-Dev"
else
  NAME="Huddle"; BUNDLE_ID="app.huddle.Huddle"; ICON="AppIcon"
fi

if [ ! -d Vendor/MatrixRustSDK/MatrixSDKFFI.xcframework ]; then
  echo "error: the Matrix SDK isn't built yet. Run Scripts/build-sdk.sh first (needs Rust, 10-20 min)." >&2
  exit 1
fi

# HUDDLE_VERSION (e.g. from a release tag) stamps the version, else the latest v-tag does; the build
# number counts commits, so builds after a tag still tell apart.
VERSION="${HUDDLE_VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c "$CONFIG" --product Huddle
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Huddle"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "Resources/$ICON.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/Huddle"
if [ "$CONFIG" = release ]; then strip -x "$APP/Contents/MacOS/Huddle"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Huddle</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

if [ -n "${HUDDLE_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$HUDDLE_SIGN_IDENTITY"
else
  IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')"
  IDENTITY="${IDENTITY:--}"
fi
codesign --force --sign "$IDENTITY" "$APP"
touch "$APP"  # Make Finder and the Dock pick up icon changes.
TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [ "$IDENTITY" = "-" ]; then
  echo "Built $APP $VERSION ($BUILD) ($CONFIG, ad-hoc signed: the Keychain will ask again after each rebuild)"
else
  echo "Built $APP $VERSION ($BUILD) ($CONFIG, Team ID $TEAM)"
fi
