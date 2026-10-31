# Releasing the Masko player

Every package carries the same version. Pushing a version tag (`0.1.11`, no
`v`) publishes the npm, pub.dev and Maven Central packages from
`.github/workflows/release.yml`; the Swift package is the tag itself, with
its engine zips on the GitHub release of the version that last changed them.
Everything below runs from the command line.

## What we publish

| Package | Registry | Name | Published by |
| --- | --- | --- | --- |
| Web player | npm | `@masko/player` | the `web` job |
| React Native and Expo | npm | `@masko/player-react-native` | the `react-native` job |
| Flutter | pub.dev | `masko_player` (publisher `masko.ai`) | the `flutter` job |
| Android | Maven Central | `ai.masko:player` (namespace `ai.masko`) | the `android` job |
| iPhone, iPad, Mac, visionOS | Swift Package Manager | `https://github.com/masko-ai/masko-player`, product `MaskoPlayer` | the tag, and the zips of `scripts/release-apple.sh` |
| Web player, script tag | jsDelivr | `@masko/player@<version>/dist/masko-player.js` | follows npm by itself |

## Credentials, set up once

- **npm**: each package's settings on npmjs.com trust this repository and
  the file `release.yml` (trusted publishing): no token. Renaming the
  workflow file stops npm publishing.
- **pub.dev**: `masko_player`'s admin page has automated publishing on for
  this repository and the tag pattern `{{version}}`: no token.
- **Maven Central**: Maven Central has no trusted publishing. The Central
  Portal user token of the `ai.masko` namespace and the signing key are
  repository secrets: `MAVEN_CENTRAL_USERNAME`, `MAVEN_CENTRAL_PASSWORD`,
  `MAVEN_SIGNING_KEY` (the whole `gpg --export-secret-keys --armor` output)
  and `MAVEN_SIGNING_KEY_PASSWORD`. The key is "Masko <paul@masko.ai>",
  fingerprint `00AF89E3A6DEC4FD307D932AC09BB817B5BE20CA`, public on
  keyserver.ubuntu.com and keys.openpgp.org. A new token (central.sonatype.com,
  View Account, Generate User Token) goes in with
  `gh secret set MAVEN_CENTRAL_USERNAME` and `gh secret set MAVEN_CENTRAL_PASSWORD`.
- **Swift**: nothing: SwiftPM reads the tag, and `Package.swift` names the
  zips on the GitHub release.

## Release

In the workspace checkout, the remote of `masko-ai/masko-player` is named
`public` and the local branch `public` pushes to `main`; in a plain clone,
read `origin` and `main`.

```bash
scripts/set-version.sh 0.1.11     # every package, its lockfile and the install lines
# Write flutter/CHANGELOG.md's "## 0.1.11" entry (pub.dev shows it).
scripts/release-apple.sh 0.1.11   # only when the engine or the Swift bindings changed (below)
git commit -am "0.1.11: <what changed>"
git push                          # then wait for CI on main: gh run watch
git tag 0.1.11
git push public 0.1.11            # starts release.yml
gh run watch "$(gh run list --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

`scripts/set-version.sh` says what it left: the CHANGELOG entry when it is
missing, and what moves after the release (below). Each job of the release
workflow first checks its package's version against the tag, so a package
left at the old version stops its own job before it publishes.

**The Swift engine zips.** `Package.swift` downloads the engine
(`MaskoPlayerFFI.xcframework.zip`) and dav1d (`dav1d.xcframework.zip`) from
the GitHub release its `releaseURL` and `dav1dReleaseURL` name. When
`engine/`, `bindings/`, dav1d or `apple/Sources/MaskoPlayer/Generated/`
changed since that release, run `scripts/release-apple.sh <version>` before
the commit: it builds both zips and points `Package.swift` at the new
release. Commit `Package.swift` with the bindings of the same build, and
right after pushing the tag, make the release, since apps that resolve the
tag download from it:

```bash
gh release create 0.1.11 target/apple-release/0.1.11/*.zip --title 0.1.11 --notes "<what changed>"
```

Without an engine change, `Package.swift` keeps the earlier release's zips
(0.1.10 uses 0.1.9's) and the version needs no GitHub release.

## Check

```bash
npm view @masko/player version
npm view @masko/player-react-native version
curl -s https://pub.dev/api/packages/masko_player | node -p 'JSON.parse(require("fs").readFileSync(0)).latest.version'
curl -s -o /dev/null -w '%{http_code}\n' https://repo1.maven.org/maven2/ai/masko/player/0.1.11/player-0.1.11.pom
gh release view 0.1.11            # with new Swift zips: both are attached
```

Each prints the new version (Maven: `200`). Maven Central takes 5 to 30
minutes to show a release, its search page a few hours.

## When a job fails

Each registry takes a version once and never deletes it. The packages that
went out stay out; rerun only the jobs that failed:

```bash
gh run rerun <run id> --failed
```

A failure in the code itself (a test, the build) is fixed in the next patch
version: every package moves to it, including the ones already published.

By hand, from a Mac with this repository:

- npm (needs an npm account that can publish to `@masko`):
  `scripts/build-web.sh --package && (cd web && npm publish --access public)`,
  and `scripts/build-react-native.sh && (cd react-native && npm publish --access public)`.
- pub.dev (a Google account of the `masko.ai` publisher):
  `scripts/build-flutter.sh && (cd flutter && dart pub publish)`.
- Maven Central: `scripts/build-android.sh`, then in `android/`,
  `./gradlew :player:publishAndReleaseToMavenCentral` with the token and the
  key as `ORG_GRADLE_PROJECT_*` variables (`android/README.md`, "Publish to
  Maven Central").
- Swift: `gh release upload <version> <zip>` adds a missing zip. The same
  commit makes the same zip again (`SOURCE_DATE_EPOCH`, `apple/README.md`).

## After the release

- `examples/electron` installs the published web player:
  `npm install @masko/player@<version>` there, and commit.
- masko.ai's docs (masko-core, `content/docs/player*.md`) name the Android
  version and the Swift minimum: `git grep -n -F <old version> -- content/docs`.
