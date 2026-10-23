#!/usr/bin/env bash
# Builds the engine for iPhone, iPad and Mac and makes the Swift package's
# binary target: apple/MaskoPlayerFFI.xcframework (the static library, its C
# header and module map) and the generated Swift bindings, internal to the
# MaskoPlayer module, in apple/Sources/MaskoPlayer/Generated/.
#
#   scripts/build-apple.sh
#
# Uses the repository's own Rust toolchain (scripts/env.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=env.sh
source scripts/env.sh

export IPHONEOS_DEPLOYMENT_TARGET=15.0
export MACOSX_DEPLOYMENT_TARGET=13.0

CRATE=masko-player-ffi
LIB=libmasko_player_ffi.a
MODULE=masko_player_ffiFFI
TARGETS=(
  aarch64-apple-darwin
  x86_64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)

for target in "${TARGETS[@]}"; do
  echo "==> $CRATE for $target"
  cargo rustc -p "$CRATE" --release --target "$target" --crate-type staticlib
done

echo "==> uniffi-bindgen"
cargo build -p uniffi-bindgen
BINDGEN="$ROOT/target/debug/uniffi-bindgen"

WORK="$ROOT/target/apple"
rm -rf "$WORK"
mkdir -p "$WORK/generated" "$WORK/macos" "$WORK/ios-simulator"

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

echo "==> apple/MaskoPlayerFFI.xcframework"
XCFRAMEWORK="$ROOT/apple/MaskoPlayerFFI.xcframework"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
  -library "$WORK/macos/$LIB" -headers "$HEADERS" \
  -library "target/aarch64-apple-ios/release/$LIB" -headers "$HEADERS" \
  -library "$WORK/ios-simulator/$LIB" -headers "$HEADERS" \
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

echo "Built $XCFRAMEWORK"
echo "Wrote $GENERATED/masko_player_ffi.swift"
