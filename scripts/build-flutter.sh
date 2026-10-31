#!/usr/bin/env bash
# Builds what masko_player, the Flutter package (flutter/), takes from this
# repository and copies it into the package, which builds from these copies
# alone, here and from pub.dev:
#
# - flutter/ios/masko_player/vendor/MaskoPlayer: the Swift player
#   (apple/Sources/MaskoPlayer);
# - flutter/ios/masko_player/vendor/MaskoPlayerFFI.xcframework: the engine and
#   the AV1 decoder dav1d for iOS devices and the simulator, merged into one
#   library (react-native/scripts/ios-libraries.mjs), which Swift Package
#   Manager and CocoaPods both take;
# - flutter/android/player: the Kotlin player's sources, bindings, engine
#   libraries and R8 rules, which flutter/android/build.gradle.kts builds into
#   the plugin;
# - flutter/LICENSE and flutter/THIRD_PARTY_NOTICES.md.
#
# The engines are built first when they are missing (scripts/build-apple.sh,
# scripts/build-dav1d-apple.sh, scripts/build-android.sh). Run this again
# after changing the Swift player, the Kotlin player or the engine.
#
# Usage: scripts/build-flutter.sh
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

PACKAGE="$ROOT/flutter"
VENDOR="$PACKAGE/ios/masko_player/vendor"

echo "==> The Swift player and the iOS engine"
rm -rf "$VENDOR"
mkdir -p "$VENDOR"
rsync -a --exclude .DS_Store "$ROOT/apple/Sources/MaskoPlayer/" "$VENDOR/MaskoPlayer/"
node "$ROOT/react-native/scripts/ios-libraries.mjs" "$VENDOR" >/dev/null

echo "==> The Kotlin player and the Android engine"
rm -rf "$PACKAGE/android/player"
mkdir -p "$PACKAGE/android/player"
for part in java generated jniLibs; do
  rsync -a --exclude .DS_Store "$PLAYER/src/main/$part/" "$PACKAGE/android/player/$part/"
done
cp "$PLAYER/consumer-rules.pro" "$PACKAGE/android/player/consumer-rules.pro"

cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$PACKAGE/"

echo "Copied the Swift and Kotlin players and their engines into $PACKAGE"
