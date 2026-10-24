#!/usr/bin/env bash
# Builds the engine for the Android library `ai.masko:player` (android/):
#
# - libmasko_player_ffi.so for arm64-v8a, armeabi-v7a and x86_64 (NDK 27
#   clang, API 24, 16 KB pages) into android/player/src/main/jniLibs/<abi>/;
# - the host library for the JVM unit tests, where JNA finds it
#   (android/player/src/test/resources/<jna platform>/);
# - the Kotlin MaskoEngine bindings (UniFFI) into
#   android/player/src/main/generated/;
# - android/player/engine.stamp: a hash of the engine sources, then the hash
#   of each file built from them. The Gradle build refuses files that do not
#   match it, so a stale engine is never packaged or published.
#
# Builds use their own target directory (target/android) so they never fight
# other builds over target/release. Rust panics unwind instead of aborting, so
# an engine bug reaches the app as an exception, not a crash. The Android
# libraries are built with local folders remapped, so they name no path of
# this machine.
#
# Usage: scripts/build-android.sh [--host-only]
#   --host-only: the host library and the bindings only, for the JVM tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=env.sh
source "$ROOT/scripts/env.sh"

NDK_VERSION="${MASKO_NDK_VERSION:-27.1.12297006}"
API=24
NDK="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/$NDK_VERSION}"
export CARGO_TARGET_DIR="$ROOT/target/android"
PLAYER="$ROOT/android/player"
JNI="$PLAYER/src/main/jniLibs"
GENERATED="$PLAYER/src/main/generated"
STAMP="$PLAYER/engine.stamp"
CARGO_FLAGS=(--release --locked --config 'profile.release.panic="unwind"')

host_only=false
[[ "${1:-}" == "--host-only" ]] && host_only=true

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi | cut -d' ' -f1
}

# What the libraries and bindings are built from, one path per line, sorted.
# android/player/build.gradle.kts lists the same files.
engine_sources() {
  (
    cd "$ROOT"
    {
      printf '%s\n' Cargo.toml Cargo.lock rust-toolchain.toml android/uniffi.toml scripts/build-android.sh
      for crate in engine bindings/uniffi bindings/uniffi-bindgen; do
        printf '%s\n' "$crate/Cargo.toml"
        if [[ -f "$crate/build.rs" ]]; then printf '%s\n' "$crate/build.rs"; fi
        find "$crate/src" -type f -name '*.rs'
      done
    } | LC_ALL=C sort
  )
}

# One hash for all of them: the hash of the lines "<file hash>  <path>".
sources_hash() {
  engine_sources | while IFS= read -r f; do printf '%s  %s\n' "$(sha256 "$ROOT/$f")" "$f"; done | sha256
}

sources="$(sources_hash)"
# A host-only build keeps the Android libraries of the same sources.
kept=""
if $host_only && [[ -f "$STAMP" ]] && grep -qx "sources $sources" "$STAMP"; then
  kept="$(grep '  src/main/jniLibs/' "$STAMP" || true)"
fi
# No stamp until this build is done: a failed build leaves nothing Gradle accepts.
rm -f "$STAMP"

# The host library for JVM tests, in the folder JNA searches on this machine.
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) host_dir="darwin-aarch64"; host_lib="libmasko_player_ffi.dylib" ;;
  Darwin-x86_64) host_dir="darwin-x86-64"; host_lib="libmasko_player_ffi.dylib" ;;
  Linux-x86_64) host_dir="linux-x86-64"; host_lib="libmasko_player_ffi.so" ;;
  Linux-aarch64) host_dir="linux-aarch64"; host_lib="libmasko_player_ffi.so" ;;
  *) echo "Unsupported host $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

echo "==> Host library ($host_dir)"
cargo build -p masko-player-ffi "${CARGO_FLAGS[@]}"
mkdir -p "$PLAYER/src/test/resources/$host_dir"
cp "$CARGO_TARGET_DIR/release/$host_lib" "$PLAYER/src/test/resources/$host_dir/$host_lib"

echo "==> Kotlin bindings"
cargo build -p uniffi-bindgen --locked
rm -rf "$GENERATED"
mkdir -p "$GENERATED"
(cd "$ROOT" && "$CARGO_TARGET_DIR/debug/uniffi-bindgen" generate \
  "$CARGO_TARGET_DIR/release/$host_lib" \
  --language kotlin \
  --config "$ROOT/android/uniffi.toml" \
  --no-format \
  --out-dir "$GENERATED")

built=(
  "src/main/generated/ai/masko/player/engine/masko_player_ffi.kt"
  "src/test/resources/$host_dir/$host_lib"
)

if ! $host_only; then
  if [[ ! -d "$NDK" ]]; then
    echo "NDK not found at $NDK (set ANDROID_NDK_HOME or MASKO_NDK_VERSION)" >&2
    exit 1
  fi
  TOOLCHAIN="$(echo "$NDK"/toolchains/llvm/prebuilt/*)/bin"

  # Panic messages name source files: map this machine's folders to neutral
  # names (the last matching prefix wins, so the most precise comes last).
  # Android 15 devices may use 16 KB memory pages.
  rustflags=(
    -C "link-arg=-Wl,-z,max-page-size=16384"
    "--remap-path-prefix=$HOME=~"
    "--remap-path-prefix=$ROOT=/masko-player"
    "--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo"
  )
  # Separated by 0x1f, so folders with spaces stay whole.
  encoded_rustflags="$(IFS=$'\x1f'; echo "${rustflags[*]}")"

  # abi  rust target  clang prefix
  targets=(
    "arm64-v8a aarch64-linux-android aarch64-linux-android$API"
    "armeabi-v7a armv7-linux-androideabi armv7a-linux-androideabi$API"
    "x86_64 x86_64-linux-android x86_64-linux-android$API"
  )

  for entry in "${targets[@]}"; do
    read -r abi target clang <<<"$entry"
    echo "==> $abi ($target)"
    env_target="$(echo "$target" | tr '[:lower:]-' '[:upper:]_')"
    cc_target="$(echo "$target" | tr '-' '_')"
    export "CARGO_TARGET_${env_target}_LINKER=$TOOLCHAIN/$clang-clang"
    export "CC_${cc_target}=$TOOLCHAIN/$clang-clang"
    export "AR_${cc_target}=$TOOLCHAIN/llvm-ar"
    CARGO_ENCODED_RUSTFLAGS="$encoded_rustflags" \
      cargo build -p masko-player-ffi --target "$target" "${CARGO_FLAGS[@]}"
    so="$CARGO_TARGET_DIR/$target/release/libmasko_player_ffi.so"
    if LC_ALL=C grep -q -a -F "$HOME" "$so"; then
      echo "$abi: the library still names a folder under $HOME" >&2
      exit 1
    fi
    mkdir -p "$JNI/$abi"
    cp "$so" "$JNI/$abi/libmasko_player_ffi.so"
    built+=("src/main/jniLibs/$abi/libmasko_player_ffi.so")
  done
  kept=""
fi

# The sources must not have changed while they were built.
if [[ "$(sources_hash)" != "$sources" ]]; then
  echo "The engine sources changed during the build; run scripts/build-android.sh again." >&2
  exit 1
fi

{
  echo "# Written by scripts/build-android.sh; android/player/build.gradle.kts checks it."
  echo "sources $sources"
  for f in "${built[@]}"; do printf '%s  %s\n' "$(sha256 "$PLAYER/$f")" "$f"; done
  if [[ -n "$kept" ]]; then printf '%s\n' "$kept"; fi
} >"$STAMP.tmp"
mv "$STAMP.tmp" "$STAMP"

echo "==> Done"
if $host_only; then
  ls -l "$PLAYER/src/test/resources/$host_dir/$host_lib"
else
  ls -l "$JNI"/*/libmasko_player_ffi.so "$PLAYER/src/test/resources/$host_dir/$host_lib"
fi
