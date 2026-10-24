// The engine's WebAssembly inlined in the JavaScript, in base64: esbuild's
// base64 loader (build.mjs) makes the import that text. TypeScript reads the
// file's wasm-bindgen declarations instead, hence the cast.
import wasm from './wasm/masko_player_wasm_bg.wasm';

export default wasm as unknown as string;
