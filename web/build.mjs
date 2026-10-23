// Builds @masko/player into dist/: the ES modules ("." and "./react") with
// the engine's .wasm beside them, the one-file script build with the
// WebAssembly inlined, and the type declarations. Run scripts/build-web.sh
// first: it puts the engine in src/wasm/.
import { build } from 'esbuild';
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const dist = join(here, 'dist');
const wasm = join(here, 'src', 'wasm', 'masko_player_wasm_bg.wasm');
const { version } = JSON.parse(readFileSync(join(here, 'package.json'), 'utf8'));

if (!existsSync(wasm)) {
  console.error('src/wasm/ is missing: run scripts/build-web.sh first');
  process.exit(1);
}
rmSync(dist, { recursive: true, force: true });

const common = {
  bundle: true,
  target: ['es2020', 'chrome87', 'firefox78', 'safari14'],
  legalComments: 'none',
  logLevel: 'warning'
};

// The ES modules: the core and the React component share one chunk.
await build({
  ...common,
  entryPoints: { index: 'src/index.ts', react: 'src/react.ts' },
  outdir: dist,
  format: 'esm',
  splitting: true,
  chunkNames: 'core-[hash]',
  external: ['react', 'react-dom'],
  platform: 'browser'
});
copyFileSync(wasm, join(dist, 'masko_player_wasm_bg.wasm'));
const react = join(dist, 'react.js');
writeFileSync(react, `'use client';\n${readFileSync(react, 'utf8')}`);

// The script build: one file, window.MaskoPlayer.mount(element, options).
await build({
  ...common,
  entryPoints: ['src/script.ts'],
  outfile: join(dist, 'masko-player.js'),
  format: 'iife',
  globalName: 'MaskoPlayer',
  minify: true,
  loader: { '.wasm': 'binary' },
  define: { __VERSION__: JSON.stringify(version) },
  logOverride: { 'empty-import-meta': 'silent' },
  banner: { js: `/*! @masko/player ${version} | MIT */` }
});
const script = join(dist, 'masko-player.js');
writeFileSync(script, readFileSync(script, 'utf8').replace('__VERSION__', version));

execFileSync(join(here, 'node_modules', '.bin', 'tsc'), ['-p', 'tsconfig.build.json'], { stdio: 'inherit', cwd: here });
// The sources import './x.ts' (Node runs the tests from source); published
// declarations import './x.js', which every TypeScript setup resolves.
const types = join(dist, 'types');
for (const name of readdirSync(types)) {
  const file = join(types, name);
  writeFileSync(file, readFileSync(file, 'utf8').replace(/(from '\.\/[\w-]+)\.ts'/g, "$1.js'"));
}
console.log('built', dist);
