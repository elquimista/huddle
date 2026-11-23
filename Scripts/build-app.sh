#!/bin/bash
# Builds the app into ./build without Xcode.
#   Scripts/build-app.sh          # release -> build/Huddle.app
#   Scripts/build-app.sh debug    # debug   -> build/Huddle Dev.app (own bundle ID, data folder, Keychain item, icon)
#   HUDDLE_VERSION=1.2.0 Scripts/build-app.sh   # stamps that version (the release workflow passes the
#                                               # tag; without it, the latest v-tag's, else 0.1.0)
#   HUDDLE_BUILD=99 Scripts/build-app.sh       # stamps that build number (to make a test update)
#   HUDDLE_ARCHS="arm64 x86_64" Scripts/build-app.sh debug   # which Macs it runs on (see below)
# Icons come from Resources/*.icns; regenerate them with Scripts/make-icons.sh.
# Updates: Sparkle is bundled; see "Updates" below for the feed and the key updates are signed with.
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
  echo "error: the Matrix SDK isn't built yet. Run Scripts/build-sdk.sh first (needs Rust, 20-40 min)." >&2
  exit 1
fi

# HUDDLE_VERSION (e.g. from a release tag) stamps the version, else the latest v-tag does; the build
# number counts commits, so builds after a tag still tell apart. It counts from 1000: Sparkle offers
# whichever release has the higher build number, not version, and the macOS 13 line
# (legacy/macos-13) counts its own commits from 0, so every 1.x has to come out above every 0.13.x.
VERSION="${HUDDLE_VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="${HUDDLE_BUILD:-$((1000 + $(git rev-list --count HEAD 2>/dev/null || echo 0)))}"
# The commit it's built from, shown in About ("+": with changes not yet committed).
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || true)"
if [ -n "$COMMIT" ] && ! git diff --quiet HEAD -- 2>/dev/null; then COMMIT="$COMMIT+"; fi

# Updates (Sparkle; Sources/Huddle/Core/AppUpdater.swift). The release app reads the appcast the
# release workflow publishes, and takes only updates signed with the private half of this public
# key (README, Releases). The Dev build gets no feed, so it never updates itself from releases;
# for testing, HUDDLE_SPARKLE_PUBLIC_KEY gives it a test key and HUDDLE_DEV_UPDATE_FEED (at launch)
# a test feed.
UPDATES_REPO="${HUDDLE_UPDATES_REPO:-elquimista/huddle-releases}"
FEED_URL="${HUDDLE_UPDATE_FEED:-https://raw.githubusercontent.com/$UPDATES_REPO/main/appcast.xml}"
RELEASE_PUBLIC_KEY="4pwtUCqEBuFh/G/s/0PCJtG9gqgyZW1qW4L+NYqJtuA="
if [ "$CONFIG" = release ]; then
  UPDATE_KEYS="<key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>${HUDDLE_SPARKLE_PUBLIC_KEY:-$RELEASE_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>"
elif [ -n "${HUDDLE_SPARKLE_PUBLIC_KEY:-}" ]; then
  UPDATE_KEYS="<key>SUPublicEDKey</key><string>$HUDDLE_SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><false/>"
else
  UPDATE_KEYS="<key>SUEnableAutomaticChecks</key><false/>"
fi

# A release runs on both kinds of Mac, Apple Silicon and Intel, as one app. The Dev build is for
# this Mac's own kind only, which builds in half the time; HUDDLE_ARCHS="arm64 x86_64" makes it
# both, to try the Intel half under Rosetta (arch -x86_64 "build/Huddle Dev.app/Contents/MacOS/Huddle").
if [ -n "${HUDDLE_ARCHS:-}" ]; then
  read -ra ARCHS <<< "$HUDDLE_ARCHS"
elif [ "$CONFIG" = release ]; then
  ARCHS=(arm64 x86_64)
else
  ARCHS=()
fi
# Each kind is built on its own and the two joined with lipo. (Asked for both at once, SwiftPM
# hands the build to Xcode's build system, whose linker crashes on the Matrix SDK's library.)
if [ ${#ARCHS[@]} -eq 0 ]; then
  swift build -c "$CONFIG" --product Huddle
  BIN="$(swift build -c "$CONFIG" --show-bin-path)/Huddle"
else
  SLICES=()
  for arch in "${ARCHS[@]}"; do
    swift build -c "$CONFIG" --product Huddle --arch "$arch"
    SLICES+=("$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)/Huddle")
  done
  BIN="$(dirname "${SLICES[0]}")/Huddle-universal/Huddle"
  mkdir -p "$(dirname "$BIN")"
  lipo -create "${SLICES[@]}" -output "$BIN"
fi

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "Resources/$ICON.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Licenses "$APP/Contents/Resources/"  # the open-source libraries' licenses (linked from About)
# Element Call, the call screen: a web app run in a web view (Sources/Huddle/Core/Calls.swift).
Scripts/fetch-element-call.sh
ditto Vendor/ElementCall/dist "$APP/Contents/Resources/ElementCall"
cp Vendor/ElementCall/LICENSE.txt "$APP/Contents/Resources/Licenses/Element-Call-LICENSE.txt"
cp "$BIN" "$APP/Contents/MacOS/Huddle"
if [ "$CONFIG" = release ]; then strip -x "$APP/Contents/MacOS/Huddle"; fi
ditto "$(swift build -c "$CONFIG" ${ARCHS[0]+--arch "${ARCHS[0]}"} --show-bin-path)/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

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
    <key>HuddleCommit</key><string>$COMMIT</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Felix-Andre Lee</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key><string>Huddle uses the microphone for calls and voice messages.</string>
    $UPDATE_KEYS
</dict>
</plist>
PLIST

if [ -n "${HUDDLE_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$HUDDLE_SIGN_IDENTITY"
else
  IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')"
  IDENTITY="${IDENTITY:--}"
fi
# With a real certificate, the hardened runtime: no other process can inject code into the app
# (DYLD_INSERT_LIBRARIES and the like) and with it read the sessions in the Keychain, and only
# code signed by the same team loads. Ad-hoc builds, which have no team for Sparkle to share,
# go without. The Dev build may still be debugged and sampled; the release app may not.
RUNTIME=()
ENTITLEMENTS=()
if [ "$IDENTITY" != "-" ]; then
  RUNTIME=(--options runtime)
  # The hardened runtime keeps the microphone from an app that doesn't say it uses one: calls do.
  APP_ENTITLEMENTS="$(mktemp -t huddle-entitlements).plist"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.device.audio-input bool true" "$APP_ENTITLEMENTS" >/dev/null
  if [ "$CONFIG" = debug ]; then
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$APP_ENTITLEMENTS" >/dev/null
  fi
  ENTITLEMENTS=(--entitlements "$APP_ENTITLEMENTS")
fi
# Sparkle's parts, innermost first, then the framework, then the app that holds it.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for part in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} --preserve-metadata=entitlements "$SPARKLE/Versions/B/$part"
done
codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} "$SPARKLE"
codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} "$APP"
touch "$APP"  # Make Finder and the Dock pick up icon changes.
TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [ "$IDENTITY" = "-" ]; then
  echo "Built $APP $VERSION ($BUILD) ($CONFIG, ad-hoc signed: the Keychain will ask again after each rebuild)"
else
  echo "Built $APP $VERSION ($BUILD) ($CONFIG, Team ID $TEAM)"
fi
