# What every player does

The engine (`engine/`) holds every rule of `rules.md`. Each platform's player
(`web/`, `apple/`, `android/`, `react-native/`) only plays video and carries
out the engine's commands, the same way everywhere. This page is that
contract.

## The clock

A player keeps one **play time** in whole milliseconds: 0 when the mascot
starts, moving with real time, stopped while the player is paused (rules
11.2). It pauses itself while the mascot cannot be seen: a hidden page on
the web, a view out of its window or an app in the background on iPhone and
iPad, a view off screen on Android, a view out of its window on the Mac.
Every engine call takes the current play time. A player never computes a
rule itself.

## Calls into the engine

| When                                         | Call                                  |
| -------------------------------------------- | ------------------------------------- |
| The delivery is loaded                       | `new(delivery JSON)`; a refusal is an `error` event with its code |
| Before starting, the app sets or fires values | `set` / `fire` with play time 0       |
| The mascot starts (`autoPlay`, or `play()`)  | `start(0)`                            |
| The app calls `set(name, value)`             | `set(name, value, now)`               |
| The app calls `fire(name)`                   | `fire(name, now)`                     |
| The person clicks the mascot                 | `click(now)`                          |
| The pointer enters or leaves the mascot      | `hover(true/false, now)`              |
| The engine's `nextWake()` time arrives       | `advance(now)`; then read `nextWake()` again |
| A clip's first frame is on screen            | `clipShown(edge, now)`                |
| The clip on screen plays its last frame      | `clipEnded(edge, now)`                |
| A clip being shown cannot play               | `clipFailed(edge, now)`               |
| A preload fails                              | `markUnplayable(edge)`                |
| A clip marked unplayable loads later         | `markPlayable(edge)`                  |
| The app calls `reset()`                      | `reset(now)`                          |
| An editor calls `preview.showPose` / `playMove` | `previewShowPose` / `previewPlayMove` |

After every call, run the returned commands in order, then schedule a wake
for `nextWake()` (cancel the previous one). A late wake is fine: the engine
runs everything that was due first.

## Commands from the engine

- **`showClip { edge, kind, rate }`**: show this edge's clip from its first
  frame, now, at playback rate `rate`, never backwards.
  - If the same edge is already on screen as a pose clip, this is its next
    loop: restart the same video without a visible cut (seek to 0 and play,
    or let a native loop run on).
  - Otherwise use the other of two persistent video slots: load the clip (or
    take it from the preload cache), wait until its **first frame is
    decoded**, then make it visible and hide the old slot in the same frame.
    No crossfade, ever. Pause the old slot after the swap.
  - Report `clipShown(edge, now)` when this clip's first frame is on screen:
    at the swap, or at once when a pose clip restarts in place. Report it
    once per showing; the engine counts the clip's safety net from it, and
    a clip not reported shown within 10 s counts as failed (rules 9.3).
  - Report `clipEnded(edge, now)` when this clip reaches its end, once per
    showing. Report `clipFailed(edge, now)` if it cannot load or decode.
  - For `kind: move`, tell the app the clip's `movement` (from the delivery
    edge) so it can move the mascot; the player never moves itself.
- **`showStill { pose }`**: show the pose's `transparentThumbnailUrl`
  image, or nothing, in place of video. The engine ends a still by itself.
- **`preload { edge }`**: load that edge's file into a small cache (a few
  clips) so a later `showClip` swaps without waiting.
- **`playSound { edge }`**: play the edge's `sound.url` at `sound.volume`,
  looping when `sound.loop` is true.
- **`stopSounds { onlyLooping }`**: stop looping sounds, or every sound.
- **`poseEntered { pose }`**: tell the app (`pose` event).
- **`interrupted { edge }`**: the move on screen is cut by a person's move;
  the next `showClip` replaces it at once.
- **`spent { name, used }`**: tell the app a fire is done (`reactionDone`
  event, with `used`).
- **`error { code }`**: tell the app (`error` event).

## The file and the size

From the edge's `videos`, a player picks the file its platform plays with
transparency:

| Where                                       | File |
| ------------------------------------------- | ---- |
| Safari, and any browser on iPhone and iPad   | `hevc` |
| Chrome, Firefox, Edge                        | `webm` (HEVC only on Safari, because some Chrome setups decode HEVC but draw a box) |
| iPhone, iPad and Mac apps                    | `hevc` |
| Android apps                                 | `stacked` (colour above, transparency below), drawn with a shader |

With `videos.variants` (manifest mode), take the smallest size at least as
large as the mascot on screen times the screen density, else the base file.
If a file fails, a web player tries the other format once before reporting
`clipFailed`.

## What the app sees

The same names on every platform:

- `set(name, value)`, `fire(name)`, `reset()`, `play()`, `pause()`,
  `destroy()`, and `position()`: `{ clip, time }`, the clip on screen (an
  edge, or `still:<pose>`) and its clip time in seconds, read only. Before
  anything shows, `clip` is null and `time` 0; a still's `time` is 0.
- `autoPlay`: the app's value wins when it gives one, else the graph's
  `autoPlay`, else true (rules.md 11.1).
- `sound`: off by default. When on, a clip's own voice (`hasAudio`) is
  heard; edge sounds play either way.
- Events, with the same data everywhere:
  - `pose { pose }`: the mascot entered this pose.
  - `clip { clip, kind, rate }`: a clip is on screen. `clip` is the edge, or
    `still:<pose>`; `kind` is `pose`, `move` or `still`; `rate` is its
    playback rate (1 for a still).
  - `reactionDone { name, used }`: a fire is done, used by a start or spent
    unused.
  - `movement { edge, movement, rate, seconds }`: a move whose edge has a
    `movement` is on screen; `seconds` is the edge's `duration` divided by
    `rate`, how long the move lasts.
  - `error { code, detail? }`: a code from rules.md or the player, and a
    detail when there is one. A refused delivery gives the engine's own
    code, so text that is not JSON is `unreadable` everywhere. Only an
    engine that cannot run gives the player's `engine_unavailable` (web) or
    `engine_failed` (Android).
- `preview.showPose(id)` and `preview.playMove(id)`, for editors and tools.
- Signed links expire (`deliveryAccess.signedUrlExpiresAt`). Five minutes
  before that (halfway there when less than ten minutes are left), the player
  asks the app's `getDelivery()` for a fresh delivery of the same release
  and takes it as `updateDelivery` does. When `getDelivery` fails, or gives
  nothing it can take, the player reports it and asks again 30 seconds
  later; links that last no longer than the old ones are asked for again 30
  seconds later too.
- `updateDelivery(delivery)`: the app gives a fresh delivery of the release
  that is playing. The player swaps the URLs only; the engine keeps running,
  files already cached keep playing, and clips that failed are tried again
  from the new links. Another release (another `release.id`, or another
  graph once links are left out) is refused with `error`
  `refresh_mismatch`, a delivery that cannot be read with `refresh_failed`.
  On the web and in React Native, the components call it when their
  `delivery` prop changes to new links of the same release.

## Tests every platform runs

1. **The scenarios, through its binding.** Every `spec/fixtures/*.json` runs
   through the platform's own engine binding with the ideal player of
   `fixtures/README.md`, and must give the same trace as `cargo test`.
2. **The player against a fake video layer.** Command handling (two slots,
   swap only after the first frame, loop restart, end and failure reports,
   preload cache, sounds, events) runs against a scripted fake decoder.
3. **Real video.** At least one real transparent clip plays and swaps on the
   platform's real decoder (a browser, the iOS simulator or macOS, an Android
   emulator or a JVM-side decoder check where an emulator is not available).
