#!/bin/bash
# Compiles the Matrix Rust SDK for macOS (Apple Silicon) and vendors the result
# into Vendor/MatrixRustSDK. Element only publishes prebuilt binaries for iOS.
# Requires Rust (brew install rustup && rustup default stable). Takes 10-20 min.
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
git -C "$SRC" checkout -q FETCH_HEAD

(cd "$SRC" && cargo xtask swift build-framework --release \
    --target aarch64-apple-darwin --macos-deployment-target 14.0)

GENERATED="$SRC/bindings/apple/generated"
rm -rf "$OUT/MatrixSDKFFI.xcframework" "$OUT/Sources/MatrixRustSDK"
mkdir -p "$OUT/Sources/MatrixRustSDK"
cp -R "$GENERATED/MatrixSDKFFI.xcframework" "$OUT/"
cp "$GENERATED"/swift/*.swift "$OUT/Sources/MatrixRustSDK/"
echo "Vendored SDK $SDK_COMMIT into $OUT"
