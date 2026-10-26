// Makes the pod's one prebuilt library: the engine (apple/MaskoPlayerFFI.xcframework,
// scripts/build-apple.sh) and dav1d (apple/dav1d.xcframework,
// scripts/build-dav1d-apple.sh) merged into MaskoPlayerFFI.xcframework, with
// their iOS device and simulator slices only. CocoaPods copies every
// xcframework of a pod into the same folder, so two would delete each
// other's headers.
//
//   node scripts/ios-libraries.mjs <output folder>

import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

export function makeIosLibraries(output) {
  const ffi = join(repo, 'apple/MaskoPlayerFFI.xcframework');
  const dav1d = join(repo, 'apple/dav1d.xcframework');
  for (const [path, how] of [
    [ffi, 'run scripts/build-apple.sh.'],
    [dav1d, 'run scripts/build-dav1d-apple.sh.']
  ]) {
    if (!existsSync(join(path, 'Info.plist'))) throw new Error(`${path} is missing: ${how}`);
  }
  const work = mkdtempSync(join(tmpdir(), 'masko-ios-libraries-'));
  try {
    const args = ['-create-xcframework'];
    for (const slice of readdirSync(ffi).filter((name) => name.startsWith('ios-'))) {
      if (!existsSync(join(dav1d, slice))) throw new Error(`dav1d has no ${slice} slice`);
      const folder = join(work, slice);
      mkdirSync(join(folder, 'Headers'), { recursive: true });
      execFileSync('libtool', [
        '-static',
        '-o',
        join(folder, 'libmasko_player_ffi.a'),
        join(ffi, slice, 'libmasko_player_ffi.a'),
        join(dav1d, slice, 'libdav1d.a')
      ], { stdio: ['ignore', 'ignore', 'inherit'] });
      cpSync(join(ffi, slice, 'Headers'), join(folder, 'Headers'), { recursive: true });
      cpSync(join(dav1d, slice, 'Headers'), join(folder, 'Headers'), { recursive: true });
      args.push('-library', join(folder, 'libmasko_player_ffi.a'), '-headers', join(folder, 'Headers'));
    }
    const target = join(output, 'MaskoPlayerFFI.xcframework');
    rmSync(target, { recursive: true, force: true });
    args.push('-output', target);
    execFileSync('xcodebuild', args, { stdio: ['ignore', 'ignore', 'inherit'] });
    return target;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const output = process.argv[2];
  if (!output) {
    console.error('usage: node scripts/ios-libraries.mjs <output folder>');
    process.exit(2);
  }
  mkdirSync(output, { recursive: true });
  console.log(makeIosLibraries(resolve(output)));
}
