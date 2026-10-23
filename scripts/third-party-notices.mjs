#!/usr/bin/env node
// Writes THIRD_PARTY_NOTICES.md at the repository root: every Rust crate
// compiled into the engine builds (bindings/wasm for the web, bindings/uniffi
// for Apple and Android), with its version, license, repository and the full
// text of its license files from the crate's source in the Cargo registry.
//
//   source scripts/env.sh && node scripts/third-party-notices.mjs
//
// `cargo metadata` gives each crate's license, repository and source folder.
// Which crates are compiled in comes from `cargo tree` for each binding and
// target, normal dependencies only: `cargo metadata` resolves features for the
// whole workspace, so it would also list uniffi's command-line crates, which
// only the uniffi-bindgen tool uses. Proc-macro crates are listed too: they
// run while compiling, but the code they write is part of the output.
//
// A crate whose source has no license file gets the standard text of its
// license from scripts/licenses/<SPDX id>.txt; the script stops when there is
// none.
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'THIRD_PARTY_NOTICES.md');

const builds = [
  { crate: 'masko-player-wasm', platform: 'Web', targets: ['wasm32-unknown-unknown'] },
  {
    crate: 'masko-player-ffi',
    platform: 'Apple',
    targets: ['aarch64-apple-darwin', 'x86_64-apple-darwin', 'aarch64-apple-ios', 'aarch64-apple-ios-sim', 'x86_64-apple-ios']
  },
  {
    crate: 'masko-player-ffi',
    platform: 'Android',
    targets: ['aarch64-linux-android', 'armv7-linux-androideabi', 'x86_64-linux-android']
  }
];

const cargo = (args) =>
  execFileSync('cargo', args, { cwd: root, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });

const metadata = JSON.parse(cargo(['metadata', '--format-version', '1', '--locked']));
const workspace = new Set(metadata.workspace_members);
const byNameVersion = new Map(
  metadata.packages.filter((p) => !workspace.has(p.id)).map((p) => [`${p.name} ${p.version}`, p])
);

// name version -> { pkg, platforms }
const linked = new Map();
for (const build of builds) {
  for (const target of build.targets) {
    const tree = cargo([
      'tree', '--locked', '-p', build.crate, '-e', 'normal',
      '--target', target, '--prefix', 'none', '--format', '{p}'
    ]);
    for (const line of tree.split('\n')) {
      const m = /^(\S+) v(\S+)/.exec(line);
      if (!m) continue;
      const pkg = byNameVersion.get(`${m[1]} ${m[2]}`);
      if (!pkg) continue; // a crate of this workspace
      const entry = linked.get(`${m[1]} ${m[2]}`) ?? { pkg, platforms: new Set() };
      entry.platforms.add(build.platform);
      linked.set(`${m[1]} ${m[2]}`, entry);
    }
  }
}

const LICENSE_FILE = /^(licen[cs]e|copying|copyright|notice|unlicense)/i;
function licenseFiles(pkg) {
  const dir = dirname(pkg.manifest_path);
  const names = new Set(readdirSync(dir).filter((f) => LICENSE_FILE.test(f)));
  if (pkg.license_file) names.add(pkg.license_file);
  const files = [...names].sort().map((name) => ({ name, text: readFileSync(join(dir, name), 'utf8') }));
  if (files.length) return files;
  const standard = join(root, 'scripts', 'licenses', `${pkg.license}.txt`);
  if (!existsSync(standard)) {
    throw new Error(`${pkg.name} ${pkg.version} ships no license file and scripts/licenses/${pkg.license}.txt does not exist`);
  }
  return [{ name: `${pkg.license} (standard text)`, text: readFileSync(standard, 'utf8'), standard: true }];
}

// Trailing spaces and Windows line ends removed, one final newline.
const tidy = (text) =>
  text.replace(/\r\n?/g, '\n').split('\n').map((l) => l.replace(/\s+$/, '')).join('\n').replace(/\n+$/, '') + '\n';
const fence = (text) => '`'.repeat(Math.max(3, ...[...text.matchAll(/`+/g)].map((m) => m[0].length + 1)));
// GitHub's heading anchors: lower case, punctuation dropped, spaces to hyphens.
const anchor = (heading) => heading.toLowerCase().replace(/[^a-z0-9 _-]/g, '').replace(/ /g, '-');
const ORDER = ['Web', 'Apple', 'Android'];

const crates = [...linked.values()].sort((a, b) =>
  a.pkg.name === b.pkg.name ? a.pkg.version.localeCompare(b.pkg.version) : a.pkg.name.localeCompare(b.pkg.name)
);
const rustcOut = (args) => execFileSync('rustc', args, { cwd: root, encoding: 'utf8' }).trim();
const rustVersion = /^rustc (\S+)/.exec(rustcOut(['--version']))[1];
const sysroot = rustcOut(['--print', 'sysroot']);

const lines = [];
const md = (...l) => lines.push(...l);
md(
  '# Third-party notices',
  '',
  'The Masko player engine is compiled, with the Rust crates below, into the',
  'WebAssembly of the web package (`bindings/wasm`), the `MaskoPlayerFFI`',
  'xcframework of the Swift package and the `libmasko_player_ffi.so` libraries',
  'of the Android library (`bindings/uniffi`). Each crate keeps its own',
  "license; the texts below are copied from each crate's source. Packages",
  'built from this repository ship this file with `LICENSE`.',
  '',
  '`scripts/third-party-notices.mjs` writes this file from `Cargo.lock`. Run it',
  'again after a dependency changes; do not edit this file by hand.',
  '',
  '## Crates',
  '',
  '| Crate | Version | License | In |',
  '| ----- | ------- | ------- | -- |'
);
for (const { pkg, platforms } of crates) {
  const where = ORDER.filter((p) => platforms.has(p)).join(', ');
  md(`| [${pkg.name}](#${anchor(`${pkg.name} ${pkg.version}`)}) | ${pkg.version} | ${pkg.license ?? 'see its license file'} | ${where} |`);
}

const mpl = crates.filter(({ pkg }) => /\bMPL-2\.0\b/.test(pkg.license ?? ''));
if (mpl.length) {
  md(
    '',
    '## Source code of the MPL-2.0 crates',
    '',
    'These crates are licensed under the Mozilla Public License 2.0. They are',
    'compiled in unmodified, and their source code is available from crates.io',
    'and from their repository:',
    ''
  );
  for (const { pkg } of mpl) {
    md(`- ${pkg.name} ${pkg.version}: https://crates.io/crates/${pkg.name}/${pkg.version} and ${pkg.repository ?? 'no repository given'}`);
  }
}

md(
  '',
  '## The Rust standard library',
  '',
  `The engine also compiles in the standard library of Rust ${rustVersion}, licensed`,
  'under MIT OR Apache-2.0. Its full notices, which also cover the crates it',
  'uses, are in `share/doc/rust/COPYRIGHT-library.html` of every Rust',
  `toolchain, and its source code is at https://github.com/rust-lang/rust/tree/${rustVersion}.`,
  '',
  '## License texts'
);

const seen = new Map(); // text -> where it was first printed
const print = (heading, files) => {
  for (const file of files) {
    const text = tidy(file.text);
    md('', `#### ${file.name}`, '');
    const first = seen.get(text);
    if (first) {
      md(`The same text as \`${first.file}\` of [${first.heading}](#${anchor(first.heading)}).`);
      continue;
    }
    seen.set(text, { file: file.name, heading });
    if (file.standard) md("The crate's source has no license file. This is the standard text of its license.", '');
    const f = fence(text);
    md(f + 'text', text.replace(/\n$/, ''), f);
  }
};
for (const { pkg } of crates) {
  const heading = `${pkg.name} ${pkg.version}`;
  md(
    '',
    `### ${heading}`,
    '',
    `- License: ${pkg.license ?? 'see its license file'}`,
    `- Repository: ${pkg.repository ?? pkg.homepage ?? 'none given'}`,
    `- Source: https://crates.io/crates/${pkg.name}/${pkg.version}`
  );
  print(heading, licenseFiles(pkg));
}

const stdLicenses = join(sysroot, 'share', 'doc', 'rust', 'licenses');
const stdFiles = ['MIT.txt', 'Apache-2.0.txt'].filter((f) => existsSync(join(stdLicenses, f)));
if (stdFiles.length) {
  md('', `### Rust ${rustVersion} standard library`, '', '- License: MIT OR Apache-2.0', '- Repository: https://github.com/rust-lang/rust');
  print(
    `Rust ${rustVersion} standard library`,
    stdFiles.map((name) => ({ name, text: readFileSync(join(stdLicenses, name), 'utf8') }))
  );
}

writeFileSync(out, lines.join('\n') + '\n');
console.log(`Wrote THIRD_PARTY_NOTICES.md: ${crates.length} crates, ${mpl.length} under MPL-2.0`);
