# Masko player

[![CI](https://github.com/masko-ai/masko-player/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/masko-ai/masko-player/actions/workflows/ci.yml)

One player for Masko mascots on every platform. One Rust engine holds every
canvas rule; each platform adds only its video players and its view. Apps
call `set` and `fire`, and the canvas decides which clip plays.

| Platform              | Package                      | Folder          |
| --------------------- | ---------------------------- | --------------- |
| Web (any framework)   | `@masko/player`              | `web/`          |
| iPhone, iPad and Mac  | `MaskoPlayer` Swift package  | `apple/`        |
| Android               | `ai.masko:player`            | `android/`      |
| React Native and Expo | `@masko/player-react-native` | `react-native/` |

Install:

- **Web**: `npm install @masko/player` ([web/README.md](web/README.md)).
- **Apple**: add `https://github.com/masko-ai/masko-player` from `0.1.0` in
  Xcode or `Package.swift`, product `MaskoPlayer`
  ([apple/README.md](apple/README.md)).
- **React Native and Expo**: `npm install @masko/player-react-native`
  ([react-native/README.md](react-native/README.md)); it carries the iOS and
  Android players.
- **Android**: not on Maven Central yet. Build it from this repository
  ([android/README.md](android/README.md)): `scripts/build-android.sh`, then
  `./gradlew :player:publishReleasePublicationToLocalRepository` in
  `android/` writes `ai.masko:player:0.1.0` to `android/player/build/repo`;
  add that folder to your app's Maven repositories.

The React Native package wraps the Swift and Kotlin players; it adds no
rules of its own.

Every player reads a release delivery: the `delivery` object of the Masko
API's `GET /v1/canvases/{canvasId}/releases/{releaseId}/delivery`, with
`target=web`, `target=apple` or `target=android` for the files that
platform plays.

## What is here

- `spec/rules.md`: the rulebook every player follows.
- `spec/player.md`: what every platform's player does with the engine's
  commands, the file it picks, what the app sees, and the tests it runs.
- `spec/fixtures/`: the scenarios that prove the rulebook, run by the engine
  and by every platform through its own binding.
- `spec/release.schema.json`: the JSON Schema of the release delivery.
- `engine/`: the Rust engine; `engine/SIZE.md` has its size.
- `bindings/wasm/`: the engine for the web (wasm-bindgen).
- `bindings/uniffi/`: the engine for Swift and Kotlin (UniFFI).
- `examples/`: a small app per platform.
- `scripts/`: `setup.sh` and `env.sh` (the Rust toolchain, the Android SDK),
  the engine builds for each platform, and `third-party-notices.mjs`.
- `.github/workflows/ci.yml`: the checks below, on GitHub Actions.

## Set up

You need, for the platforms you build:

- curl, and a C compiler and linker: Xcode or its Command Line Tools on
  macOS.
- Node.js 22.18 or later, with npm: web and React Native.
- ffmpeg with libvpx-vp9: the web browser tests make their own clips with it.
- Xcode 16 or later, with an iOS simulator: Apple, and React Native on iOS.
- Java 17, and the Android SDK with NDK 27.1.12297006 at `ANDROID_HOME`
  (Android Studio's folder by default): Android, and React Native on
  Android.

Then install Rust into `.toolchain/`, inside this repository:

```bash
scripts/setup.sh
```

It installs rustup, the Rust version and targets of `rust-toolchain.toml`,
and the wasm-bindgen CLI the web build needs, without touching your own
Rust. Then it lists which of the tools above this machine has.
`scripts/env.sh` uses `.toolchain/` when it exists, and your own rustup
otherwise.

Each check below runs from the repository root. GitHub Actions runs them
on every push to `main` and every pull request (`.github/workflows/ci.yml`):
the engine, web, Android and React Native on Ubuntu, Apple on macOS 15. The
iOS simulator tests and each platform's device checks run by hand.

The engine, with the scenarios and the engine tests, its formatting and
its lints:

```bash
source scripts/env.sh
cargo test -p masko-player-engine
cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
```

Web:

```bash
(cd web && npm install && npx playwright install chromium)
scripts/build-web.sh --package
(cd web && npm run typecheck && npm test && npx playwright test)
```

iPhone, iPad and Mac:

```bash
scripts/build-apple.sh
swift test
xcodebuild test -scheme MaskoPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Android:

```bash
scripts/build-android.sh
(cd android && ./gradlew :player:testDebugUnitTest)
```

React Native (these checks need no native build; the example app needs
`scripts/build-react-native.sh` first):

```bash
(cd react-native && npm install && npm run typecheck && npm run lint && npm test)
```

Each platform's README has its own details and device checks.

## License

MIT. See `LICENSE`. The compiled engine contains Rust crates under their
own licenses, listed with their texts in `THIRD_PARTY_NOTICES.md`
(`node scripts/third-party-notices.mjs` writes it). Every package built from
this repository ships both `LICENSE` and `THIRD_PARTY_NOTICES.md`.
