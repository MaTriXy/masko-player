// The one-file script build: `<script src="masko-player.js">` then
// `MaskoPlayer.mount(element, { delivery })`. The engine's WebAssembly is
// inlined, so nothing else is fetched but the clips.

import wasm from './inline.ts';
import { fromBase64, setWasmSource } from './engine.ts';
import { mountMascot } from './mount.ts';

setWasmSource(fromBase64(wasm));

export { mountMascot as mount, mountMascot };
export const version = __VERSION__;
