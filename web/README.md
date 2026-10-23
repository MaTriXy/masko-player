# @masko/player for the web

Plays a Masko mascot release in any web page, with transparency. Every
canvas rule runs in the shared Rust engine (`../engine`), compiled to
WebAssembly; this package only plays video and carries out the engine's
commands, as `../spec/player.md` describes.

It is not on npm yet. Build it from this repository (`../README.md`, Set
up), then pack it and install the `.tgz` in your app:

```bash
npm install                         # here, in web/
../scripts/build-web.sh --package
npm pack                            # writes masko-player-0.1.0.tgz
```

## Use

```ts
import { mountMascot } from '@masko/player';

const mascot = mountMascot(document.getElementById('mascot')!, {
  delivery, // the release delivery object, its JSON, or the API response around it
  getDelivery: () => fetch('/my-api/delivery').then((r) => r.json())
});
mascot.on('pose', ({ pose }) => console.log(pose));
mascot.set('working', true);
mascot.fire('celebrate');
```

The element sets the mascot's size. `mountMascot` returns at once; the
engine loads in the background and calls made meanwhile are kept.

With React (17 or later):

```tsx
import { MaskoPlayer, type MaskoHandle } from '@masko/player/react';

const ref = useRef<MaskoHandle>(null);
<MaskoPlayer ref={ref} delivery={delivery} style={{ width: 240, height: 240 }} onPose={(e) => setPose(e.pose)} />;
ref.current?.fire('celebrate');
```

Without a build step, one file with the engine inlined,
`dist/masko-player.js`, served next to your page:

```html
<script src="masko-player.js"></script>
<script>
  const mascot = MaskoPlayer.mount(document.getElementById('mascot'), { delivery });
</script>
```

## What the app can call

- `set(name, value)` with a boolean or a number, `fire(name)`. Values set
  before the start choose the first pose.
- `play()`, `pause()`, `reset()`, `destroy()`, `position()`, and
  `preview.showPose(id)` / `preview.playMove(id)` (editors only).
- Events: `pose`, `clip`, `reactionDone`, `movement`, `error`.
- Options: `sound` (off by default; lets a clip's own voice be heard, edge
  sounds play either way), `autoPlay` (defaults to the canvas), `pointer`
  (on by default: clicks and the pointer reach the canvas as `click` and
  `pointerHover`).

## What the player does by itself

- Picks the file: HEVC on Safari and on every iPhone and iPad browser, WebM
  elsewhere, and the other one once if a file fails. With size variants, the
  smallest one at least as large as the mascot on screen.
- Two video elements: the next clip swaps in only once its first frame is
  decoded, so there is always a mascot on screen and never a crossfade.
- Preloads what the engine asks for, plays edge sounds, and pauses while the
  page is hidden.
- Shows a tap-to-play button when the browser blocks autoplay, and the
  canvas's click effect (a small ripple) where the person clicks.
- Asks `getDelivery` for fresh signed links before they expire and swaps the
  links only; the mascot keeps playing.

The ES module build loads `masko_player_wasm_bg.wasm` next to itself. To
host it elsewhere, call `setWasmSource(url)` before the first mascot mounts.

## Build and test

```bash
npm install
npx playwright install chromium     # once, for the browser tests
../scripts/build-web.sh --package   # the engine, then dist/
npm run typecheck
npm test                            # the 64 scenarios through WebAssembly, player and unit tests
npx playwright test                 # real transparent video in Chromium
```

The browser tests make their clips with ffmpeg, which needs libvpx-vp9.
