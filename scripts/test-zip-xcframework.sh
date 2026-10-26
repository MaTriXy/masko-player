#!/usr/bin/env bash
# Checks scripts/zip-xcframework.sh on a small xcframework: the same commit
# gives the same zip whatever the files' own dates and the machine's time
# zone, and every entry is dated to that commit, not to an old fixed date that
# macOS's temporary-folder cleanup deletes.
#
#   scripts/test-zip-xcframework.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "test-zip-xcframework: $*" >&2
  exit 1
}

# The dates of the zip's entries, one line per date.
dates() {
  zipinfo -T "$1" | awk '$1 ~ /^[-dl]/ { print $7 }' | sort -u
}

X="$WORK/Fake.xcframework"
mkdir -p "$X/macos-arm64/Headers"
echo '<plist/>' > "$X/Info.plist"
echo 'lib' > "$X/macos-arm64/libfake.a"
echo 'int fake(void);' > "$X/macos-arm64/Headers/fake.h"
ln -s macos-arm64 "$X/Current"

"$ROOT/scripts/zip-xcframework.sh" "$X" "$WORK/a.zip"
touch "$X/Info.plist"
TZ=Asia/Tokyo "$ROOT/scripts/zip-xcframework.sh" "$X" "$WORK/b.zip"
cmp -s "$WORK/a.zip" "$WORK/b.zip" || fail "two zips of the same commit differ"

epoch="$(git -C "$ROOT" log -1 --format=%ct)"
want="$(TZ=UTC date -r $((epoch - epoch % 2)) +%Y%m%d.%H%M%S)"
[[ "$(dates "$WORK/a.zip")" == "$want" ]] || fail "entries dated $(dates "$WORK/a.zip" | tr '\n' ' '), not the commit's $want"

zipinfo -1 "$WORK/a.zip" | grep -x 'Fake.xcframework/Info.plist' >/dev/null || fail "no Fake.xcframework/Info.plist at the top"
zipinfo "$WORK/a.zip" | grep '^l.* Fake.xcframework/Current$' >/dev/null || fail "Current is not kept as a link"

SOURCE_DATE_EPOCH=1800000001 "$ROOT/scripts/zip-xcframework.sh" "$X" "$WORK/c.zip"
[[ "$(dates "$WORK/c.zip")" == "20270115.080000" ]] || fail "SOURCE_DATE_EPOCH gave $(dates "$WORK/c.zip" | tr '\n' ' ')"

echo "test-zip-xcframework: ok"
