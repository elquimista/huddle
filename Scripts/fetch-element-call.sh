#!/bin/bash
# Fetches Element Call, the call screen (a web app Huddle runs in a web view, as Element X does),
# at a pinned version into Vendor/ElementCall, for build-app.sh to bundle. It comes from Element's
# Swift package of its embedded build; the source maps are left out (about half its size).
# Element Call is licensed under the AGPL-3.0 (or Element's commercial licence): its licence goes in
# the app's Licenses folder, with where its source is.
set -euo pipefail
cd "$(dirname "$0")/.."

# Bump to update Element Call (a tag of github.com/element-hq/element-call-swift).
VERSION="0.28.2"
OUT="Vendor/ElementCall"

if [ -f "$OUT/VERSION" ] && [ "$(cat "$OUT/VERSION")" = "$VERSION" ]; then exit 0; fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git -c advice.detachedHead=false clone -q --depth 1 --branch "$VERSION" https://github.com/element-hq/element-call-swift "$TMP/source"
rm -rf "$OUT"
mkdir -p "$OUT"
rsync -a --exclude '*.map' "$TMP/source/Sources/dist/" "$OUT/dist/"
{
  echo "Element Call $VERSION, the call screen, bundled from https://github.com/element-hq/element-call-swift"
  echo "Its source: https://github.com/element-hq/element-call/tree/v$VERSION"
  echo
  cat "$TMP/source/LICENSE-AGPL-3.0"
} > "$OUT/LICENSE.txt"
echo "$VERSION" > "$OUT/VERSION"
echo "Fetched Element Call $VERSION into $OUT"
