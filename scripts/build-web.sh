#!/usr/bin/env bash
# Builds the engine for the web: the masko-player-wasm crate for
# wasm32-unknown-unknown (release), wasm-bindgen's `--target web` glue into
# web/src/wasm/, and `wasm-opt -Oz` when binaryen is installed in web/.
#
#   scripts/build-web.sh            engine only (web/src/wasm/)
#   scripts/build-web.sh --package  engine, then the npm package (web/dist/)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/env.sh"

WANT_BINDGEN="0.2.129"
OUT="$ROOT/web/src/wasm"
WASM="$ROOT/target/wasm32-unknown-unknown/release/masko_player_wasm.wasm"

have_bindgen="$(wasm-bindgen --version | awk '{print $2}')"
lock_bindgen="$(awk '/^name = "wasm-bindgen"$/{getline; gsub(/[^0-9.]/, ""); print; exit}' "$ROOT/Cargo.lock")"
if [[ "$have_bindgen" != "$WANT_BINDGEN" || "$lock_bindgen" != "$WANT_BINDGEN" ]]; then
  echo "wasm-bindgen CLI is $have_bindgen and Cargo.lock has $lock_bindgen; both must be $WANT_BINDGEN" >&2
  exit 1
fi

cargo build -p masko-player-wasm --release --target wasm32-unknown-unknown --manifest-path "$ROOT/Cargo.toml"

rm -rf "$OUT"
mkdir -p "$OUT"
wasm-bindgen --target web --out-dir "$OUT" --out-name masko_player_wasm "$WASM"

OPT="$ROOT/web/node_modules/.bin/wasm-opt"
if [[ -x "$OPT" ]]; then
  "$OPT" -Oz \
    --enable-bulk-memory --enable-nontrapping-float-to-int --enable-sign-ext \
    --enable-mutable-globals --enable-reference-types --enable-multivalue \
    -o "$OUT/masko_player_wasm_bg.opt.wasm" "$OUT/masko_player_wasm_bg.wasm"
  mv "$OUT/masko_player_wasm_bg.opt.wasm" "$OUT/masko_player_wasm_bg.wasm"
else
  echo "wasm-opt not found in web/node_modules (npm install in web/); keeping the unoptimized .wasm" >&2
fi

echo "engine: $(wc -c < "$OUT/masko_player_wasm_bg.wasm" | tr -d ' ') bytes in $OUT"

if [[ "${1:-}" == "--package" ]]; then
  (cd "$ROOT/web" && node build.mjs)
fi
