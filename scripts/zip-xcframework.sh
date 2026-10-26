#!/usr/bin/env bash
# Zips an xcframework as SwiftPM downloads it, for scripts/release-apple.sh:
#
#   scripts/zip-xcframework.sh apple/MaskoPlayerFFI.xcframework out/MaskoPlayerFFI.xcframework.zip
#
# The xcframework sits at the top of the zip, which is what SwiftPM looks for.
# The same commit gives the same zip: sorted entries, no extended attributes,
# symbolic links kept as links, and every file dated to the commit it is built
# from (SOURCE_DATE_EPOCH, in seconds, sets another date). Not an old fixed
# date: SwiftPM keeps the zip's dates when it unpacks the engine, and macOS
# deletes old files from temporary folders, so an app built in $TMPDIR lost
# the engine's Info.plist.
set -euo pipefail

if [[ $# -ne 2 || ! -d "$1" ]]; then
  echo "usage: scripts/zip-xcframework.sh <xcframework> <zip>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$(cd "$1" && pwd)"
NAME="$(basename "$SOURCE")"
ZIP="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"

EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct)}"
if [[ ! "$EPOCH" =~ ^[0-9]+$ ]]; then
  echo "error: SOURCE_DATE_EPOCH must be seconds since 1970, not '$EPOCH'" >&2
  exit 2
fi
# A zip keeps even seconds, and local times: in UTC they are the same on every machine.
EPOCH=$((EPOCH - EPOCH % 2))
export TZ=UTC
STAMP="$(date -r "$EPOCH" +%Y%m%d%H%M.%S)"

STAGE="$ZIP.stage"
trap 'rm -rf "$STAGE"' EXIT
rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"
cp -R "$SOURCE" "$STAGE/"
find "$STAGE/$NAME" -exec touch -h -t "$STAMP" {} +
(cd "$STAGE" && find "$NAME" | LC_ALL=C sort | zip -q -X -y "$ZIP" -@)
