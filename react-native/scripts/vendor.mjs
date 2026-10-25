// Before `npm pack`: copies what the package takes from the masko-player
// repository into it, so the published package builds on its own.
//
// - ios/vendor/MaskoPlayer: the Swift player (apple/Sources/MaskoPlayer).
// - ios/vendor/MaskoPlayerFFI.xcframework: the engine for iOS devices and the
//   simulator, from apple/MaskoPlayerFFI.xcframework (scripts/build-apple.sh).
// - android/player: the Kotlin player's sources, bindings and engine libraries
//   (android/player/src/main, built by scripts/build-android.sh) and its
//   R8 rules, which android/build.gradle builds into the library.
// - LICENSE and THIRD_PARTY_NOTICES.md, which every package built from this
//   repository ships.

import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const pkg = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repo = resolve(pkg, '..');

function need(path, how) {
  if (!existsSync(path)) {
    console.error(`${path} is missing: ${how}`);
    process.exit(1);
  }
}

const sources = join(repo, 'apple/Sources/MaskoPlayer');
const ffi = join(repo, 'apple/MaskoPlayerFFI.xcframework');
const kotlin = join(repo, 'android/player/src/main');
need(sources, 'run this from the masko-player repository.');
need(join(ffi, 'Info.plist'), 'run scripts/build-apple.sh.');
for (const abi of ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
  need(join(kotlin, 'jniLibs', abi, 'libmasko_player_ffi.so'), 'run scripts/build-android.sh.');
}
need(join(kotlin, 'generated/ai/masko/player/engine'), 'run scripts/build-android.sh.');

const vendor = join(pkg, 'ios/vendor');
rmSync(vendor, { recursive: true, force: true });
mkdirSync(vendor, { recursive: true });
cpSync(sources, join(vendor, 'MaskoPlayer'), {
  recursive: true,
  filter: (from) => !from.endsWith('.DS_Store')
});

// Only the iOS slices: the macOS one is not for apps.
const args = ['-create-xcframework'];
for (const slice of readdirSync(ffi).filter((name) => name.startsWith('ios-'))) {
  args.push('-library', join(ffi, slice, 'libmasko_player_ffi.a'), '-headers', join(ffi, slice, 'Headers'));
}
args.push('-output', join(vendor, 'MaskoPlayerFFI.xcframework'));
execFileSync('xcodebuild', args, { stdio: ['ignore', 'ignore', 'inherit'] });

const androidPlayer = join(pkg, 'android/player');
rmSync(androidPlayer, { recursive: true, force: true });
for (const part of ['java', 'generated', 'jniLibs']) {
  cpSync(join(kotlin, part), join(androidPlayer, part), {
    recursive: true,
    filter: (from) => !from.endsWith('.DS_Store')
  });
}
cpSync(join(repo, 'android/player/consumer-rules.pro'), join(androidPlayer, 'consumer-rules.pro'));

cpSync(join(repo, 'LICENSE'), join(pkg, 'LICENSE'));
cpSync(join(repo, 'THIRD_PARTY_NOTICES.md'), join(pkg, 'THIRD_PARTY_NOTICES.md'));

console.log(`Vendored the Swift and Kotlin players and their engines into ${pkg}`);
