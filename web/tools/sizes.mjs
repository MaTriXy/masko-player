// Prints the size of what the package ships: raw, gzip -9 and brotli -q 11.
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { brotliCompressSync, constants, gzipSync } from 'node:zlib';

const dist = join(dirname(fileURLToPath(import.meta.url)), '..', 'dist');
const named = ['masko_player_wasm_bg.wasm', 'masko-player.js', 'index.js', 'react.js'];
// The rest are the chunks: the shared core and the inlined engine.
const files = [...named, ...readdirSync(dist).filter((f) => f.endsWith('.js') && !named.includes(f))];
const fmt = (n) => n.toLocaleString('en-US').padStart(9);
console.log(`${'file'.padEnd(34)} ${'raw'.padStart(9)} ${'gzip'.padStart(9)} ${'brotli'.padStart(9)}`);
for (const f of files) {
  const b = readFileSync(join(dist, f));
  const gz = gzipSync(b, { level: 9 }).length;
  const br = brotliCompressSync(b, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
  console.log(`${f.padEnd(34)} ${fmt(b.length)} ${fmt(gz)} ${fmt(br)}`);
}
