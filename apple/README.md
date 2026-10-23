# MaskoPlayer for iPhone, iPad and Mac

The `MaskoPlayer` Swift package plays a Masko mascot release on iOS 15 and
macOS 13 or later. The Rust engine (`engine/`) decides which clip plays and
when; this package keeps the play-time clock, shows the clips on two
`AVPlayerLayer` slots and reports when they end, as `spec/player.md` says.

It has no release yet. Build the engine with `scripts/build-apple.sh` (Build
and test, below), then add this repository to your app as a local Swift
package; `Package.swift` is at the root.

```swift
import MaskoPlayer

let player = MaskoPlayer(delivery: json)   // the release delivery object
player.onEvent = { event in print(event) } // pose, clip, reactionDone, movement, error
player.set("working", true)
player.fire("celebrate")

MaskoView(player: player)                  // SwiftUI
MaskoPlayerView(player: player)            // UIView on iOS, NSView on macOS
```

- `set(_:_:)` takes a `Bool` or a number, `fire(_:)` a name. Values set right
  after the player is made choose its first pose. The player then loads the
  first frame and starts, at play time 0, once that frame is on screen; with
  `autoPlay` off it shows that frame and waits for `play()`.
- `play()`, `pause()`, `reset()`, `destroy()`, `position()` (a `Position`:
  `clip`, the edge on screen or `still:<pose>`, nil before anything shows,
  and `time`, its clip time in seconds) and `preview.showPose(_:)` /
  `preview.playMove(_:)` (editors only).
- `autoPlay` in the initializer wins over the graph's `autoPlay`; left nil,
  the graph decides, else the mascot starts at once.
- Events, the same data as on every platform: `.pose(pose:)`,
  `.clip(clip:kind:rate:)` (`kind` is `.pose`, `.move` or `.still`),
  `.reactionDone(name:used:)`, `.movement(edge:movement:rate:seconds:)`
  (`seconds` is the edge's duration at this rate) and `.error(code:detail:)`.
  A refused delivery gives the engine's own code (`unreadable` for text that
  is not JSON).
- `sound` is off by default. It lets a clip's own voice be heard; edge sounds
  play either way. The app chooses its `AVAudioSession` category.
- The view turns taps, clicks, Return and Space into `click`, and the
  pointer (Mac, iPad) into `pointerHover`. Dragging and physics stay in the
  app, which sets `heldContact`, `heldShake` and `falling` itself.
- Signed links: pass `getDelivery`, an async closure that fetches the same
  release again. The player calls it five minutes before
  `deliveryAccess.signedUrlExpiresAt` (halfway there when less than ten
  minutes are left) and swaps the links only; files already downloaded keep
  playing. When it throws or gives something the player cannot take, the
  player reports `refresh_failed` or `refresh_mismatch` and asks again 30
  seconds later.
- `updateDelivery(_:)` takes a fresh delivery of the same release from the
  app at any time, with the same rules: the links only, the engine keeps
  running, clips that failed are tried again. It returns false, and reports
  `refresh_mismatch` for another release or `refresh_failed` for a delivery
  it cannot read.
- The player picks each edge's `videos.hevc` file (HEVC with alpha), or with
  `videos.variants` the smallest size at least as large as the view in
  pixels.

## Layout

- `Sources/MaskoPlayer/MaskoPlayer.swift`: the player: engine calls, commands,
  slots, stills, sounds, clock, link refresh.
- `Stage.swift`: the two-slot `AVPlayerLayer` stage. A clip swaps in only when
  its first frame is decoded and ready for display, in one transaction with
  implicit animations off.
- `Delivery.swift`: the delivery fields the player reads itself (files,
  sounds, movement, stills, link expiry).
- `MediaLoader.swift`: downloads files into a small cache, keyed by edge and
  size so a refreshed link reuses them.
- `Sounds.swift`, `Clock.swift`, `MaskoPlayerView.swift`, `MaskoView.swift`.
- `Generated/masko_player_ffi.swift`: the UniFFI bindings, written by the build
  script. Do not edit it.
- `MaskoPlayerFFI.xcframework`: the engine as a static library for macOS
  (arm64, x86_64), iOS devices (arm64) and the iOS simulator (arm64, x86_64).
  It is built locally and git-ignored.
- `tools/make-test-clips.swift`: writes the HEVC-with-alpha test clips in
  `Tests/MaskoPlayerTests/Clips`.

## Build and test

```bash
scripts/build-apple.sh   # the xcframework and the Swift bindings
swift test               # scenarios, player, file cache and real video on macOS
xcodebuild test -scheme MaskoPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

The tests run every `spec/fixtures` scenario through the Swift binding, the
player against a fake video layer, and real HEVC-with-alpha clips on
AVFoundation.

## Releases

A release publishes `MaskoPlayerFFI.xcframework` as a zip and `Package.swift`
switches its binary target from the local path to that zip's URL and
checksum (`swift package compute-checksum`), with the generated bindings
committed at the same version.
