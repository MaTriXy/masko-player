#!/usr/bin/env bash
# Builds what @masko/player-react-native (react-native/) takes from this
# repository:
#
# - the engine for iOS, apple/MaskoPlayerFFI.xcframework (scripts/build-apple.sh),
#   when it is missing; the podspec links it and apple/Sources into the pod;
# - the engine for Android (scripts/build-android.sh), when it is missing;
# - ai.masko:player, published to the local Maven repository
#   android/player/build/repo, where the package's Gradle build finds it.
#
# Run it again after changing android/player/src. Usage: scripts/build-react-native.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=env.sh
source "$ROOT/scripts/env.sh"

if [[ ! -f "$ROOT/apple/MaskoPlayerFFI.xcframework/Info.plist" ]]; then
  "$ROOT/scripts/build-apple.sh"
fi

PLAYER="$ROOT/android/player"
if [[ ! -f "$PLAYER/src/main/generated/ai/masko/player/engine/masko_player_ffi.kt" ]] \
  || ! ls "$PLAYER"/src/main/jniLibs/*/libmasko_player_ffi.so >/dev/null 2>&1; then
  "$ROOT/scripts/build-android.sh"
fi

echo "==> ai.masko:player to android/player/build/repo"
(cd "$ROOT/android" && ./gradlew --quiet :player:publishReleasePublicationToLocalRepository)
ls "$PLAYER/build/repo/ai/masko/player"
