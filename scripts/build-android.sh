#!/usr/bin/env bash
# Builds the engine for the Android library `ai.masko:player` (android/):
#
# - libmasko_player_ffi.so for arm64-v8a, armeabi-v7a and x86_64 (NDK 27
#   clang, API 24, 16 KB pages) into android/player/src/main/jniLibs/<abi>/;
# - the host library for the JVM unit tests, where JNA finds it
#   (android/player/src/test/resources/<jna platform>/);
# - the Kotlin MaskoEngine bindings (UniFFI) into
#   android/player/src/main/generated/.
#
# Builds use their own target directory (target/android) so they never fight
# other builds over target/release. Rust panics unwind instead of aborting, so
# an engine bug reaches the app as an exception, not a crash.
#
# Usage: scripts/build-android.sh [--host-only]
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
CARGO_FLAGS=(--release --locked --config 'profile.release.panic="unwind"')

host_only=false
[[ "${1:-}" == "--host-only" ]] && host_only=true

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

if $host_only; then
  exit 0
fi

if [[ ! -d "$NDK" ]]; then
  echo "NDK not found at $NDK (set ANDROID_NDK_HOME or MASKO_NDK_VERSION)" >&2
  exit 1
fi
TOOLCHAIN="$(echo "$NDK"/toolchains/llvm/prebuilt/*)/bin"

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
  # Android 15 devices may use 16 KB memory pages.
  export "CARGO_TARGET_${env_target}_RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384"
  cargo build -p masko-player-ffi --target "$target" "${CARGO_FLAGS[@]}"
  mkdir -p "$JNI/$abi"
  cp "$CARGO_TARGET_DIR/$target/release/libmasko_player_ffi.so" "$JNI/$abi/libmasko_player_ffi.so"
done

echo "==> Done"
ls -l "$JNI"/*/libmasko_player_ffi.so "$PLAYER/src/test/resources/$host_dir/$host_lib"
