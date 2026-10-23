# ai.masko:player for Android

The Masko player for Android apps: a `MaskoPlayerView` that plays a mascot
release with transparency, and a `MaskoPlayer` that apps drive with `set` and
`fire`. Every canvas rule runs in the shared Rust engine (`../engine`) through
its Kotlin binding; this library only plays video and carries out the
engine's commands, as `../spec/player.md` describes. minSdk 24.

It is not on Maven Central yet. Build it from this repository (Build,
below) and use the local Maven repository it writes.

## Android files

Android plays the `stacked` file of each edge (colour above, transparency
below), drawn with a shader. Fetch the release delivery with
`target=android` (`GET /v1/canvases/{canvasId}/releases/{releaseId}/delivery?target=android`
on the Masko API): it lists only those files. A release made before the API
put stacked files in releases has none; there every clip reports
`clipFailed`, so the engine reports `error` `clip_failed`, skips each move
straight to its target pose, and shows each pose's still
(`transparentThumbnailUrl`) in place of its clips. Releasing the canvas again
fixes it. The demo in `../examples/android` plays a small bundled delivery
that has stacked files.

## Use

```kotlin
val view = MaskoPlayerView(context)            // add it to your layout
val player = view.load(deliveryJson, MaskoPlayer.Options(
    getDelivery = { reply -> api.fetchDelivery { json -> reply(json) } },
))
player.addListener(object : MaskoPlayer.Listener {
    override fun onPose(pose: String) { }
    override fun onError(code: String, detail: String?) { }
})
player.set("working", true)
player.fire("celebrate")
player.sound = true                            // clips' own voices; off by default
player.pause(); player.play(); player.reset()
player.position()                              // clip on screen and its clip time
player.updateDelivery(freshJson)               // new links for the same release
player.destroy()                               // when you are done with it
```

`deliveryJson` is the `delivery` object of
`GET /v1/canvases/{canvasId}/releases/{releaseId}/delivery`. Call everything
on the main thread. Events arrive on the main thread from the next
main-thread turn on, so listeners added right after `load` hear the first
pose.

- **Events**, the same data as on every platform: `onPose(pose)`,
  `onClip(clip, kind, rate)` (an edge id, or `still:<pose>`; `kind` is
  `POSE`, `MOVE` or `STILL`), `onReactionDone(name, used)`,
  `onMovement(edge, movement, rate, seconds)` (a move's `movement`, for the
  app to move the mascot over `seconds`, the edge's duration at this rate)
  and `onError(code, detail)`.
- **Error codes**: the engine's (`../spec/rules.md`), a refused delivery's
  (`unreadable` for text that is not JSON, `unsupported_contract`,
  `invalid_graph`, ...), and three from the player: `engine_failed` (only
  when the engine library is missing or the engine threw),
  `refresh_failed` (`getDelivery` gave nothing, or a delivery that cannot be
  read) and `refresh_mismatch` (a delivery of another release).
- **Position**: `position()` gives `Position(clip, time)`: the edge on
  screen or `still:<pose>` (null before anything shows) and its clip time in
  seconds.
- **Taps and the pointer** on the view reach the canvas as `action::click`
  and `behavior::pointerHover`.
- **Sound**: edge sounds play either way; a clip's own voice (`hasAudio`) is
  heard only with `sound` on. The player never takes audio focus.
- **Off screen**: while the view is detached or its window hidden, the player
  pauses itself, and resumes where it stopped when it is back.
- **Signed links**: five minutes before `deliveryAccess.signedUrlExpiresAt`
  (halfway there when less than ten minutes are left), the player asks
  `getDelivery` for the same release again and swaps the links only. Files
  are cached by link without its query, so cached files keep playing. After
  a failed refresh it asks again 30 seconds later.
- **New links from the app**: `updateDelivery(json)` takes a fresh delivery
  of the same release at any time, with the same rules: the links only, the
  engine keeps running, clips that failed are tried again. It returns false,
  and reports `refresh_mismatch` or `refresh_failed`, when it cannot take it.
- **Editors**: `player.preview.showPose(id)` and `player.preview.playMove(id)`.
- `autoPlay` false shows the first frame and waits for `play()`. The app's
  `Options.autoPlay` wins over the graph's; left null, the graph decides,
  else the mascot starts at once.

The engine library is built for `arm64-v8a`, `armeabi-v7a` and `x86_64`. JNA
also ships its own library for other ABIs, so an app should keep only these:

```kotlin
android { defaultConfig { ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") } } }
```

The library brings its ProGuard rules for JNA and the bindings.

## How it plays

- `MaskoPlayer` keeps the play time (stopped while paused), one wake on the
  main thread for the engine's `nextWake()`, and carries out its commands.
- Two persistent slots, each a Media3 ExoPlayer drawing into its own
  `StackedVideoView` (a TextureView with a GL thread and the alpha shader).
  A new clip loads in the hidden slot, paused on its first frame; the swap
  happens once Media3 reports `onRenderedFirstFrame` and that frame is drawn
  in the slot's view, and hides the old slot in the same frame. No crossfade.
  A pose clip shown again restarts in place.
- The hidden slot also loads the engine's decided next clip ahead of time
  (or, during a move, the target's main clip), so most swaps happen within a
  few milliseconds of the moment the engine asks.
- `STATE_ENDED` reports `clipEnded`; a player error reports `clipFailed`, or
  marks a clip loaded ahead of time unplayable.
- `preload` puts remote files in a 200 MB disk cache. Variants: the smallest
  `videos.variants` entry with a `stacked` file at least as large as the view
  in pixels, else the base `stacked` file.

## Build

```bash
scripts/build-android.sh                 # from the repository root
cd android && ./gradlew :player:assembleRelease
```

`scripts/build-android.sh` sources `scripts/env.sh` (the Rust toolchain of
`rust-toolchain.toml`) and builds, in `target/android`:

- `libmasko_player_ffi.so` for the three ABIs with the NDK 27 clang (API 24,
  16 KB pages) into `player/src/main/jniLibs/`;
- the host library for JVM tests into `player/src/test/resources/<platform>/`;
- the Kotlin bindings (`uniffi.toml`, package `ai.masko.player.engine`) into
  `player/src/main/generated/`.

These outputs are not in git. Rust panics unwind instead of aborting, so an
engine bug reaches the player as an exception (an `engine_failed` event), not
a crash. `./gradlew :player:publishReleasePublicationToLocalRepository`
writes `ai.masko:player:0.1.0` to `player/build/repo`.

## Tests

```bash
cd android
./gradlew :player:testDebugUnitTest            # JVM, with the host engine library
./gradlew :player:connectedDebugAndroidTest    # a device or emulator
```

- `ScenariosTest`: every `../spec/fixtures/*.json` through the Kotlin
  binding, with a port of the ideal player of `engine/tests/scenarios.rs`.
  `-Pmasko.fixtures=<dir>` runs another folder.
- `MaskoPlayerTest`: the player against a fake video layer: the swap after
  the first frame, loop restarts, ends and failures, missing files, preload,
  sounds and voices, events, position, pause and play, `autoPlay`, signed
  link refresh, variants, destroy.
- `DeliveryTest`: what the player reads from a delivery.
- `RealVideoTest` (instrumented): stacked MP4s from
  `player/src/androidTest/assets/clips` (`make-clips.sh`) play through Media3,
  the shader and both slots; it checks each swap waited for a rendered and
  drawn first frame, that `STATE_ENDED` drives the loops and the move's end,
  the colours and transparency on the real screen, and a view taken off
  screen and back.

On a Mac without an emulator window:

```bash
$ANDROID_HOME/emulator/emulator -avd <avd> -no-window -no-audio -gpu swiftshader_indirect -no-snapshot-save
```
