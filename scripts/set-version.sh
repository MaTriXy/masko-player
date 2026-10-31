#!/usr/bin/env bash
# Moves every package to one version, the first step of a release
# (RELEASING.md):
#
#   scripts/set-version.sh 0.1.11
#
# The current version is web/package.json's. It changes, from that version to
# the new one: the npm packages (web/, react-native/, with their lockfiles),
# the Android library, the React Native and Flutter Android builds, Flutter's
# pubspec, and the install lines in the READMEs and the Android example. The
# release workflow checks the first six against the tag. Running it again
# with the same version changes nothing.
#
# It leaves alone what is written by hand or moves after the release, and
# says so at the end: Flutter's CHANGELOG entry, the Electron example (it
# installs the published package) and masko.ai's docs.
set -euo pipefail

NEW="${1:-}"
if [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: scripts/set-version.sh <version>, for example 0.1.11" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OLD="$(node -p "require('./web/package.json').version")"

# Each place as file|text with the old version|text with the new one.
SWAPS=(
  "android/player/build.gradle.kts|version = \"$OLD\"|version = \"$NEW\""
  "react-native/android/build.gradle|version = '$OLD'|version = '$NEW'"
  "flutter/pubspec.yaml|version: $OLD|version: $NEW"
  "flutter/android/build.gradle.kts|version = \"$OLD\"|version = \"$NEW\""
  "README.md|ai.masko:player:$OLD|ai.masko:player:$NEW"
  "android/README.md|ai.masko:player:$OLD|ai.masko:player:$NEW"
  "examples/android/app/build.gradle.kts|ai.masko:player:$OLD|ai.masko:player:$NEW"
  "flutter/README.md|masko_player: ^$OLD|masko_player: ^$NEW"
  "web/README.md|@masko/player@$OLD/|@masko/player@$NEW/"
)

# Every place must show the old version (or already the new one) before
# anything changes, so a file out of step stops the script with nothing done.
for swap in "${SWAPS[@]}"; do
  IFS='|' read -r file before after <<<"$swap"
  if ! grep -qF -- "$before" "$file" && ! grep -qF -- "$after" "$file"; then
    echo "error: $file has neither \"$before\" nor \"$after\": set it to $OLD first" >&2
    exit 1
  fi
done

for package in web react-native; do
  (cd "$package" && npm version "$NEW" --no-git-tag-version --allow-same-version --ignore-scripts >/dev/null)
done
for swap in "${SWAPS[@]}"; do
  IFS='|' read -r file before after <<<"$swap"
  BEFORE="$before" AFTER="$after" perl -pi -e 's/\Q$ENV{BEFORE}\E/$ENV{AFTER}/g' "$file"
done

echo "Version $OLD -> $NEW."
if ! grep -qx "## $NEW" flutter/CHANGELOG.md; then
  echo "- Write flutter/CHANGELOG.md's \"## $NEW\" entry: pub.dev shows it."
fi
if [ "$OLD" != "$NEW" ]; then
  echo "- Still naming $OLD (each on purpose, or to look at):"
  git grep -n -F "$OLD" -- ':!*package-lock.json' ':!*.lock' ':!flutter/CHANGELOG.md' | sed 's/^/    /' || true
fi
echo "- After the release: examples/electron (npm install @masko/player@$NEW there), and"
echo "  masko.ai's docs (git grep -n -F $OLD -- content/docs in masko-core)."
