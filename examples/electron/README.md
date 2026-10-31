# Masko player in Electron

A mascot on the desktop: a frameless, transparent window that stays on top,
in the bottom-right corner, with `@masko/player` from npm. Electron's
Chromium plays the WebM clips with transparency, so the web player works
unchanged; click Dumple to put him to work, again to let him rest. The
mascot's events print in the terminal.

```bash
cd examples/electron
npm install
npm start
```

Checked with Electron 45.2.1 on macOS: the first pose, loops, moves both
ways, the page rendered with real transparency around the mascot, and the
page loaded from local files (`loadFile`).

What an Electron app needs to know:

- The page imports `@masko/player` like any page
  (`renderer.js`). Loaded from local files, the engine's `.wasm` file next to
  the module may not be fetchable; the player then uses its built-in copy,
  with nothing to configure.
- A Content Security Policy (`index.html`) follows the web README's list.
  Four parts were checked by removing each: `script-src 'wasm-unsafe-eval'`
  (without it the engine does not start: `engine_unavailable`), `media-src`
  with the clips' host (nothing plays), `connect-src` with the same host (the
  next clips cannot download ahead) and `media-src blob:` (the downloaded
  clips are refused, and moves start late). `style-src 'unsafe-inline'` lets
  in the small style element the player adds. Clips from Masko's CDN come
  from `https://assets.masko.ai`.
- The release delivery comes from your backend, as on the web: never put the
  API key in the app.
- The window is the app's business: `transparent: true` and `frame: false`
  on the `BrowserWindow`, and a page with a transparent background
  (`main.js`, `index.html`).
