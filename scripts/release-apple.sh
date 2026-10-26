#!/usr/bin/env bash
# Makes the release zips of the engine and of dav1d for one version and points
# Package.swift at them, the way apps get both when they add this package by
# URL:
#
#   scripts/release-apple.sh 0.1.0
#
# It builds the engine (scripts/build-apple.sh) and dav1d
# (scripts/build-dav1d-apple.sh), zips apple/MaskoPlayerFFI.xcframework and
# apple/dav1d.xcframework as SwiftPM downloads them (scripts/zip-xcframework.sh,
# every file dated to the commit it builds from), prints where the zips are,
# and writes into Package.swift each zip's URL on the GitHub release named
# after the version and its checksum. Then attach both zips to that release
# and commit Package.swift with the bindings in
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
"$ROOT/scripts/build-dav1d-apple.sh"

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

DAV1D_ZIP="$OUT/dav1d.xcframework.zip"
DAV1D_URL="https://github.com/masko-ai/masko-player/releases/download/$VERSION/dav1d.xcframework.zip"
echo "==> $DAV1D_ZIP"
SOURCE_DATE_EPOCH="$DATED" "$ROOT/scripts/zip-xcframework.sh" apple/dav1d.xcframework "$DAV1D_ZIP"
DAV1D_CHECKSUM="$(swift package --package-path "$ROOT" compute-checksum "$DAV1D_ZIP")"
sed -i '' -E \
  -e "s|^let dav1dReleaseURL = \".*\"$|let dav1dReleaseURL = \"$DAV1D_URL\"|" \
  -e "s|^let dav1dReleaseChecksum = \".*\"$|let dav1dReleaseChecksum = \"$DAV1D_CHECKSUM\"|" \
  Package.swift
if ! grep -qx "let dav1dReleaseURL = \"$DAV1D_URL\"" Package.swift \
  || ! grep -qx "let dav1dReleaseChecksum = \"$DAV1D_CHECKSUM\"" Package.swift; then
  echo "error: Package.swift has no dav1dReleaseURL and dav1dReleaseChecksum lines to update" >&2
  exit 1
fi

echo
echo "Zip:      $ZIP"
echo "Size:     $(stat -f %z "$ZIP") bytes"
echo "Checksum: $CHECKSUM"
echo "Dated:    SOURCE_DATE_EPOCH=$DATED (set it to make this zip again after the release commit)"
echo "URL:      $URL"
echo "dav1d:    $DAV1D_ZIP ($(stat -f %z "$DAV1D_ZIP") bytes, checksum $DAV1D_CHECKSUM)"
echo
echo "Package.swift now downloads both. Attach both zips to the GitHub release $VERSION, and"
echo "commit Package.swift with apple/Sources/MaskoPlayer/Generated/ from this build."
