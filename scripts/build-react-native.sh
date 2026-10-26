#!/usr/bin/env bash
# Builds what @masko/player-react-native (react-native/) takes from this
# repository:
#
# - the engine for iOS, apple/MaskoPlayerFFI.xcframework (scripts/build-apple.sh),
#   and dav1d, apple/dav1d.xcframework (scripts/build-dav1d-apple.sh), when
#   they are missing; the podspec merges them and links apple/Sources into the
#   pod;
# - the engine for Android (scripts/build-android.sh), when it is missing;
#   the package's Gradle build compiles android/player/src/main into the
#   library, after a check that the engine matches the current sources.
#
# Usage: scripts/build-react-native.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=env.sh
source "$ROOT/scripts/env.sh"

if [[ ! -f "$ROOT/apple/MaskoPlayerFFI.xcframework/Info.plist" ]]; then
  "$ROOT/scripts/build-apple.sh"
fi
if [[ ! -f "$ROOT/apple/dav1d.xcframework/Info.plist" ]]; then
  "$ROOT/scripts/build-dav1d-apple.sh"
fi

PLAYER="$ROOT/android/player"
if [[ ! -f "$PLAYER/src/main/generated/ai/masko/player/engine/masko_player_ffi.kt" ]] \
  || ! ls "$PLAYER"/src/main/jniLibs/*/libmasko_player_ffi.so >/dev/null 2>&1; then
  "$ROOT/scripts/build-android.sh"
fi

echo "==> The Android engine matches its sources"
(cd "$ROOT/android" && ./gradlew --quiet :player:checkEngineLibraries)
