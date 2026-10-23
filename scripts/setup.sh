#!/usr/bin/env bash
# Installs what the engine builds need into .toolchain/, inside this
# repository: rustup, the Rust toolchain and targets of rust-toolchain.toml,
# and the wasm-bindgen CLI version scripts/build-web.sh checks. It never
# touches your own Rust (~/.rustup, ~/.cargo) or your shell profile.
# scripts/env.sh uses .toolchain/ once it exists.
#
# Then it lists the other tools each platform needs, and which ones this
# machine has. Run it again at any time: it skips what is installed.
#
#   scripts/setup.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export RUSTUP_HOME="$ROOT/.toolchain/rustup"
export CARGO_HOME="$ROOT/.toolchain/cargo"
export PATH="$CARGO_HOME/bin:$PATH"

if [[ ! -x "$CARGO_HOME/bin/rustup" ]]; then
  echo "==> rustup into .toolchain/"
  command -v curl >/dev/null || { echo "curl is needed to download rustup" >&2; exit 1; }
  # A Rust already on PATH is fine: this one lives apart, in .toolchain/. The
  # installer's "add Cargo to your PATH" advice does not apply either:
  # scripts/env.sh does it.
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
    RUSTUP_INIT_SKIP_PATH_CHECK=yes sh -s -- -y --no-modify-path --profile minimal --default-toolchain none >/dev/null
fi

echo "==> Rust toolchain, components and targets from rust-toolchain.toml"
rustup toolchain install
rustc --version

WANT_BINDGEN="$(sed -n 's/^WANT_BINDGEN="\([^"]*\)"$/\1/p' scripts/build-web.sh)"
[[ -n "$WANT_BINDGEN" ]] || { echo "no WANT_BINDGEN in scripts/build-web.sh" >&2; exit 1; }
have_bindgen=""
if [[ -x "$CARGO_HOME/bin/wasm-bindgen" ]]; then
  have_bindgen="$("$CARGO_HOME/bin/wasm-bindgen" --version | awk '{print $2}')"
fi
if [[ "$have_bindgen" != "$WANT_BINDGEN" ]]; then
  echo "==> wasm-bindgen CLI $WANT_BINDGEN into .toolchain/cargo/bin"
  cargo install wasm-bindgen-cli --version "$WANT_BINDGEN" --locked
fi
wasm-bindgen --version

# What else each platform needs. Nothing below is installed by this script.
# shellcheck source=env.sh
source "$ROOT/scripts/env.sh"
NDK_VERSION="$(sed -n 's/^NDK_VERSION="\${MASKO_NDK_VERSION:-\([^}]*\)}"$/\1/p' scripts/build-android.sh)"

found() { printf '  [found]   %s\n' "$1"; }
missing() { printf '  [missing] %s\n' "$1"; }
check() { # description, then a command that succeeds when it is there
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then found "$what"; else missing "$what"; fi
}
node_ok() {
  local v
  v="$(node --version)" || return 1
  v="${v#v}"
  local major="${v%%.*}" minor
  minor="${v#*.}"
  minor="${minor%%.*}"
  ((major > 22 || (major == 22 && minor >= 18)))
}
java_17() {
  if [[ "$(uname -s)" == "Darwin" ]] && /usr/libexec/java_home -v 17; then return 0; fi
  java -version 2>&1 | head -1 | grep -q '"17[."]'
}
ffmpeg_has() { ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " $1 "; }
ndk_there() { [[ -d "${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/$NDK_VERSION}" ]]; }

echo
echo "Rust is ready in .toolchain/. Use it with: source scripts/env.sh"
echo
echo "Engine (cargo test): nothing else."
echo
echo "Web (web/):"
check "Node.js 22.18 or later, and npm" node_ok
check "npm" command -v npm
echo "  Then: (cd web && npm install && npx playwright install chromium)"
check "ffmpeg with libvpx-vp9, for the browser tests' clips" ffmpeg_has libvpx-vp9
echo
echo "Apple (apple/, macOS only):"
check "Xcode 16 or later, with an iOS simulator" xcodebuild -version
echo
echo "Android (android/):"
check "Java 17 (JDK)" java_17
check "Android SDK at ANDROID_HOME ($ANDROID_HOME)" test -d "$ANDROID_HOME"
check "Android NDK $NDK_VERSION (sdkmanager \"ndk;$NDK_VERSION\")" ndk_there
echo "  Gradle comes with android/gradlew."
echo
echo "React Native (react-native/, examples/react-native/):"
echo "  Node.js and npm as for the web, plus the Apple and Android tools above."
check "CocoaPods, for the iOS example" command -v pod
check "ffmpeg with libx264, for the example's clips" ffmpeg_has libx264
