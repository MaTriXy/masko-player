// Before the browser tests: transparent VP9 clips made with ffmpeg (each clip
// its own colour, so a test can tell which one is on screen), a few real
// Masko clips downloaded once, and the React test page bundled.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, '..', '..');

/** Clip id, colour, seconds, motion: a loop bobs and comes back, a move slides across. */
export const CLIPS = [
  ['idle-loop', '0xf95d02', 2, 'loop'],
  ['work-loop', '0x22aa44', 2, 'loop'],
  ['to-work', '0x2255ee', 1, 'move'],
  ['to-idle', '0x9933cc', 1, 'move'],
  ['poke', '0xeecc00', 1, 'move']
];

export const REAL = {
  'idle-settle': 'https://assets.masko.ai/547bbb8e/dumple-vsa8qdhb/idle-settle-dfce9495-360.webm',
  'laptop-working': 'https://assets.masko.ai/547bbb8e/dumple-vsa8qdhb/laptop-working-dc398b45-360.webm',
  'panic-tremble': 'https://assets.masko.ai/547bbb8e/dumple-vsa8qdhb/panic-tremble-7863df85-360.webm',
  'dumpling-groove': 'https://assets.masko.ai/547bbb8e/dumple-vsa8qdhb/dumpling-groove-9fcd9f24-360.webm'
};

function ffmpeg(args) {
  execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args], { stdio: 'inherit' });
}

function makeClips(dir) {
  mkdirSync(dir, { recursive: true });
  for (const [id, color, seconds, motion] of CLIPS) {
    const out = join(dir, `${id}.webm`);
    if (existsSync(out)) continue;
    const cx = motion === 'loop' ? `120+30*sin(2*PI*T/${seconds})` : `70+100*T/${seconds}`;
    ffmpeg([
      '-f', 'lavfi',
      '-i', `color=c=${color}:s=240x240:r=30:d=${seconds},format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lt(hypot(X-(${cx}),Y-120),60),255,0)'`,
      '-c:v', 'libvpx-vp9', '-pix_fmt', 'yuva420p', '-auto-alt-ref', '0', '-b:v', '400k',
      out
    ]);
  }
  const still = join(dir, 'idle.png');
  if (!existsSync(still)) {
    ffmpeg([
      '-f', 'lavfi',
      '-i', `color=c=0xf95d02:s=240x240,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lt(hypot(X-120,Y-120),60),255,0)'`,
      '-frames:v', '1', still
    ]);
  }
  const sound = join(dir, 'tick.wav');
  if (!existsSync(sound)) ffmpeg(['-f', 'lavfi', '-i', 'sine=frequency=880:duration=0.2', sound]);
}

async function downloadReal(dir) {
  mkdirSync(dir, { recursive: true });
  for (const [id, url] of Object.entries(REAL)) {
    const out = join(dir, `${id}.webm`);
    if (existsSync(out)) continue;
    try {
      const res = await fetch(url);
      if (!res.ok) throw new Error(`${res.status}`);
      writeFileSync(out, Buffer.from(await res.arrayBuffer()));
    } catch (error) {
      console.warn(`could not download ${url}: ${error}; the real-clip test will be skipped`);
      return;
    }
  }
}

export default async function globalSetup() {
  if (!existsSync(join(web, 'dist', 'index.js')) || !existsSync(join(web, 'dist', 'masko-player.js'))) {
    throw new Error('dist/ is missing: run scripts/build-web.sh --package (or npm run build) first');
  }
  makeClips(join(here, '.clips'));
  await downloadReal(join(here, '.cache'));
  await build({
    entryPoints: [join(here, 'pages', 'react-app.tsx')],
    outfile: join(here, '.build', 'react-app.js'),
    bundle: true,
    format: 'esm',
    jsx: 'automatic',
    external: ['/pages/*'],
    define: { 'process.env.NODE_ENV': '"development"' },
    alias: { '@masko/player': join(web, 'dist', 'index.js'), '@masko/player/react': join(web, 'dist', 'react.js') },
    logLevel: 'warning'
  });
}
