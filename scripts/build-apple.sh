#!/usr/bin/env bash
# Builds the engine for iPhone, iPad, Mac, Mac Catalyst and Apple Vision Pro
# and makes the Swift package's binary target: apple/MaskoPlayerFFI.xcframework
# (the static library, its C header and module map) and the generated Swift
# bindings, internal to the MaskoPlayer module, in
# apple/Sources/MaskoPlayer/Generated/.
#
#   scripts/build-apple.sh
#
# Uses the repository's own Rust toolchain (scripts/env.sh). Package.swift
# uses this local xcframework whenever it exists; scripts/release-apple.sh
# zips it for a release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=env.sh
source scripts/env.sh

export IPHONEOS_DEPLOYMENT_TARGET=15.0
export MACOSX_DEPLOYMENT_TARGET=13.0
export XROS_DEPLOYMENT_TARGET=1.0

CRATE=masko-player-ffi
LIB=libmasko_player_ffi.a
MODULE=masko_player_ffiFFI
TARGETS=(
  aarch64-apple-darwin
  x86_64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
  aarch64-apple-ios-macabi
  x86_64-apple-ios-macabi
  aarch64-apple-visionos
  aarch64-apple-visionos-sim
)

# Source paths end up in the library (panic locations, debug info). Name them
# from the repository and the Cargo home, never from this machine's folders.
CARGO_DIR="${CARGO_HOME:-$HOME/.cargo}"
REMAP="--remap-path-prefix=$ROOT=masko-player"$'\x1f'"--remap-path-prefix=$CARGO_DIR=cargo"

for target in "${TARGETS[@]}"; do
  echo "==> $CRATE for $target"
  CARGO_ENCODED_RUSTFLAGS="$REMAP" \
    cargo rustc -p "$CRATE" --release --target "$target" --crate-type staticlib
done

for target in "${TARGETS[@]}"; do
  lib="target/$target/release/$LIB"
  if LC_ALL=C grep -a -q -e "$ROOT/" -e "$HOME/" "$lib"; then
    echo "error: $lib still contains a path on this machine" >&2
    exit 1
  fi
done

echo "==> uniffi-bindgen"
cargo build -p uniffi-bindgen
BINDGEN="$ROOT/target/debug/uniffi-bindgen"

WORK="$ROOT/target/apple"
rm -rf "$WORK"
mkdir -p "$WORK/generated" "$WORK/macos" "$WORK/ios-simulator" "$WORK/maccatalyst"

echo "==> Swift bindings"
"$BINDGEN" generate --library "target/aarch64-apple-darwin/release/$LIB" \
  --language swift --out-dir "$WORK/generated"

# One header folder per slice. The module map sits in a folder named after the
# module, so it never collides with another package's module.modulemap.
HEADERS="$WORK/headers"
mkdir -p "$HEADERS/$MODULE"
cp "$WORK/generated/$MODULE.h" "$HEADERS/$MODULE/"
cp "$WORK/generated/$MODULE.modulemap" "$HEADERS/$MODULE/module.modulemap"

echo "==> universal libraries"
lipo -create \
  "target/aarch64-apple-darwin/release/$LIB" \
  "target/x86_64-apple-darwin/release/$LIB" \
  -output "$WORK/macos/$LIB"
lipo -create \
  "target/aarch64-apple-ios-sim/release/$LIB" \
  "target/x86_64-apple-ios/release/$LIB" \
  -output "$WORK/ios-simulator/$LIB"
lipo -create \
  "target/aarch64-apple-ios-macabi/release/$LIB" \
  "target/x86_64-apple-ios-macabi/release/$LIB" \
  -output "$WORK/maccatalyst/$LIB"

echo "==> apple/MaskoPlayerFFI.xcframework"
XCFRAMEWORK="$ROOT/apple/MaskoPlayerFFI.xcframework"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
  -library "$WORK/macos/$LIB" -headers "$HEADERS" \
  -library "target/aarch64-apple-ios/release/$LIB" -headers "$HEADERS" \
  -library "$WORK/ios-simulator/$LIB" -headers "$HEADERS" \
  -library "$WORK/maccatalyst/$LIB" -headers "$HEADERS" \
  -library "target/aarch64-apple-visionos/release/$LIB" -headers "$HEADERS" \
  -library "target/aarch64-apple-visionos-sim/release/$LIB" -headers "$HEADERS" \
  -output "$XCFRAMEWORK" >/dev/null

GENERATED="$ROOT/apple/Sources/MaskoPlayer/Generated"
mkdir -p "$GENERATED"
# The bindings compile into the MaskoPlayer module (and, vendored, into the
# React Native pod's one module), so every declaration becomes internal: the
# engine, its commands and the FfiConverter helpers are not the package's API.
sed -E \
  -e 's/^([[:space:]]*)(public|open)([[:space:]]|$)/\1internal\3/' \
  -e 's/^([[:space:]]*)required public /\1required internal /' \
  "$WORK/generated/masko_player_ffi.swift" >"$GENERATED/masko_player_ffi.swift"
if grep -nE '^[[:space:]]*([[:alpha:]@_]+[[:space:]]+)*(public|open)([[:space:]]|$)' \
  "$GENERATED/masko_player_ffi.swift"; then
  echo "error: the declarations above are still public or open in the generated Swift" >&2
  exit 1
fi

# SwiftPM caches what Package.swift says by its text, not by the files around
# it: a read from before the first build still points at the release zip.
if command -v swift >/dev/null 2>&1; then
  manifest="$(swift package --package-path "$ROOT" dump-package 2>/dev/null || true)"
  if [[ -n "$manifest" ]] && ! grep -q '"path" : "apple/MaskoPlayerFFI.xcframework"' <<<"$manifest"; then
    echo "warning: SwiftPM read Package.swift before this engine existed and still uses the" >&2
    echo "warning: release zip. Run \`swift package purge-cache\` once to use this build." >&2
  fi
fi

echo "Built $XCFRAMEWORK"
echo "Wrote $GENERATED/masko_player_ffi.swift"
