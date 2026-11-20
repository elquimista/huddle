#!/bin/bash
# Compiles the Matrix Rust SDK for macOS, Apple Silicon and Intel in one library, and vendors
# the result into Vendor/MatrixRustSDK. Element only publishes prebuilt binaries for iOS.
# Requires Rust with both Mac targets (brew install rustup && rustup default stable &&
# rustup target add aarch64-apple-darwin x86_64-apple-darwin). Takes 20-40 min.
set -euo pipefail
cd "$(dirname "$0")/.."

# Commit of matrix-org/matrix-rust-sdk to build. Bump to update the SDK.
SDK_COMMIT="1278a0d747d772b387fd301afbf7ac788c3dfae8"
SRC=".build/matrix-rust-sdk"
OUT="Vendor/MatrixRustSDK"
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

mkdir -p "$SRC"
git -C "$SRC" init -q
git -C "$SRC" remote add origin https://github.com/matrix-org/matrix-rust-sdk 2>/dev/null || true
git -C "$SRC" fetch -q --depth 1 origin "$SDK_COMMIT"
# Forced, so a Cargo.lock rewritten by the last patched build goes back to the SDK's own.
git -C "$SRC" checkout -q -f FETCH_HEAD
# Patches to the SDK itself, each explained in its file in Scripts/sdk-patches.
for patch in Scripts/sdk-patches/matrix-sdk-*.patch; do
  git -C "$SRC" apply "$PWD/$patch"
done

# Patches to the SDK's dependencies, each explained in its file in Scripts/sdk-patches. ruma's
# are applied to a copy of ruma at the commit the SDK uses, and every ruma crate the SDK uses is
# built from that copy instead (all of them, so there is one of each). The [patch] table goes in
# .build/.cargo/config.toml, which cargo reads from a parent of the SDK's folder, leaving the
# SDK's own files alone. CI caches the result keyed on this script and the patches.
RUMA_COMMIT="$(grep -o -m1 'git+https://github.com/ruma/ruma?rev=[0-9a-f]*' "$SRC/Cargo.lock" | sed 's/.*rev=//')"
RUMA=".build/ruma"
mkdir -p "$RUMA" .build/.cargo
git -C "$RUMA" init -q
git -C "$RUMA" remote add origin https://github.com/ruma/ruma 2>/dev/null || true
git -C "$RUMA" fetch -q --depth 1 origin "$RUMA_COMMIT"
git -C "$RUMA" checkout -q -f FETCH_HEAD
git -C "$RUMA" clean -q -fd crates   # files an earlier run's patches added
for patch in Scripts/sdk-patches/ruma-*.patch; do
  git -C "$RUMA" apply "$PWD/$patch"
done
{
  echo '[patch."https://github.com/ruma/ruma"]'
  grep -B2 'source = "git+https://github.com/ruma/ruma' "$SRC/Cargo.lock" | sed -n 's/^name = "\(.*\)"$/\1/p' | sort -u |
    while read -r crate; do echo "$crate = { path = \"$PWD/$RUMA/crates/$crate\" }"; done
} > .build/.cargo/config.toml

(cd "$SRC" && cargo xtask swift build-framework --release \
    --target aarch64-apple-darwin --target x86_64-apple-darwin --macos-deployment-target 13.0)

GENERATED="$SRC/bindings/apple/generated"
rm -rf "$OUT/MatrixSDKFFI.xcframework" "$OUT/Sources/MatrixRustSDK"
mkdir -p "$OUT/Sources/MatrixRustSDK"
cp -R "$GENERATED/MatrixSDKFFI.xcframework" "$OUT/"
cp "$GENERATED"/swift/*.swift "$OUT/Sources/MatrixRustSDK/"
echo "Vendored SDK $SDK_COMMIT into $OUT"
