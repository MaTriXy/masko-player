#!/usr/bin/env bash
# Makes the engine's release zip for one version and points Package.swift at
# it, the way apps get the engine when they add this package by URL:
#
#   scripts/release-apple.sh 0.1.0
#
# It builds the engine (scripts/build-apple.sh), zips
# apple/MaskoPlayerFFI.xcframework as SwiftPM downloads it
# (scripts/zip-xcframework.sh, every file dated to the commit it builds from),
# prints where the zip is, and writes into Package.swift the zip's URL on the
# GitHub release named after the version and its checksum. Then attach the zip
# to that release and commit Package.swift with the bindings in
# apple/Sources/MaskoPlayer/Generated/, which this same build wrote: they must
# match the engine in the zip.
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "usage: scripts/release-apple.sh <version>, for example 0.1.0" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-apple.sh"

NAME=MaskoPlayerFFI.xcframework
OUT="$ROOT/target/apple-release/$VERSION"
ZIP="$OUT/$NAME.zip"
URL="https://github.com/masko-ai/masko-player/releases/download/$VERSION/$NAME.zip"
DATED="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> $ZIP"
SOURCE_DATE_EPOCH="$DATED" "$ROOT/scripts/zip-xcframework.sh" "apple/$NAME" "$ZIP"

CHECKSUM="$(swift package --package-path "$ROOT" compute-checksum "$ZIP")"

sed -i '' -E \
  -e "s|^let releaseURL = \".*\"$|let releaseURL = \"$URL\"|" \
  -e "s|^let releaseChecksum = \".*\"$|let releaseChecksum = \"$CHECKSUM\"|" \
  Package.swift
if ! grep -qx "let releaseURL = \"$URL\"" Package.swift \
  || ! grep -qx "let releaseChecksum = \"$CHECKSUM\"" Package.swift; then
  echo "error: Package.swift has no releaseURL and releaseChecksum lines to update" >&2
  exit 1
fi

echo
echo "Zip:      $ZIP"
echo "Size:     $(stat -f %z "$ZIP") bytes"
echo "Checksum: $CHECKSUM"
echo "Dated:    SOURCE_DATE_EPOCH=$DATED (set it to make this zip again after the release commit)"
echo "URL:      $URL"
echo
echo "Package.swift now downloads it. Attach the zip to the GitHub release $VERSION, and"
echo "commit Package.swift with apple/Sources/MaskoPlayer/Generated/ from this build."
