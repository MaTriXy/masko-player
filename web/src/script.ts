// The one-file script build: `<script src="masko-player.js">` then
// `MaskoPlayer.mount(element, { delivery })`. The engine's WebAssembly is
// inlined, so nothing else is fetched but the clips.

import wasm from './wasm/masko_player_wasm_bg.wasm';
import { setWasmSource } from './engine.ts';
import { mountMascot } from './mount.ts';

setWasmSource(wasm);

export { mountMascot as mount, mountMascot };
export const version = __VERSION__;
