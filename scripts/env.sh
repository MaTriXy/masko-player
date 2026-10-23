# Source this before building: `source scripts/env.sh`. It puts Rust on PATH
# and sets ANDROID_HOME.
#
# - With .toolchain/ (scripts/setup.sh makes it), it uses that repository-local
#   rustup, its toolchain and wasm-bindgen, and never touches the system Rust.
# - Without it, it uses your own rustup (~/.cargo/bin, or $CARGO_HOME/bin).
#   Either way rust-toolchain.toml picks the Rust version.
# - ANDROID_HOME keeps its value when it is set. Otherwise it is
#   ANDROID_SDK_ROOT, or Android Studio's default folder.
MASKO_PLAYER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")/.." && pwd)"

if [[ -x "$MASKO_PLAYER_ROOT/.toolchain/cargo/bin/rustup" && -d "$MASKO_PLAYER_ROOT/.toolchain/rustup" ]]; then
  export RUSTUP_HOME="$MASKO_PLAYER_ROOT/.toolchain/rustup"
  export CARGO_HOME="$MASKO_PLAYER_ROOT/.toolchain/cargo"
  export PATH="$CARGO_HOME/bin:$PATH"
else
  masko_cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin"
  case ":$PATH:" in
    *":$masko_cargo_bin:"*) ;;
    *) [[ -d "$masko_cargo_bin" ]] && export PATH="$masko_cargo_bin:$PATH" ;;
  esac
  unset masko_cargo_bin
  command -v rustup >/dev/null 2>&1 || echo "scripts/env.sh: no rustup found; run scripts/setup.sh" >&2
fi

if [[ -z "${ANDROID_HOME:-}" ]]; then
  if [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
    ANDROID_HOME="$ANDROID_SDK_ROOT"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    ANDROID_HOME="$HOME/Library/Android/sdk"
  else
    ANDROID_HOME="$HOME/Android/Sdk"
  fi
fi
export ANDROID_HOME
