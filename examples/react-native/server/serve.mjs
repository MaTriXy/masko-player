// The example's release delivery and clips over HTTP, as the Masko API and
// its CDN would give them: GET /delivery.json and GET /clips/<file>. It also
// relays commands to the app (App.tsx), so a terminal or a test drives it:
// POST /do/<command> (fire/celebrate, set/working/true, pause, ...), which
// the app reads with GET /next.
//
//   node server/serve.mjs [port]      (default 47290)
//
// The links are "signed" and expire five and a half minutes after each
// delivery is made, so the app's getDelivery runs: the players ask five
// minutes before links expire, or halfway when they last less than ten, so
// here about 2 min 45 s after each delivery.

import { execFileSync } from 'node:child_process';
import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const clips = join(here, '..', 'clips');
const port = Number(process.argv[2] ?? 47290);
const lifetimeMs = 5.5 * 60_000;

if (!existsSync(join(clips, 'idle.mov'))) {
  execFileSync(join(here, 'make-clips.sh'), { stdio: 'inherit' });
}

let served = 0;
/** Commands not yet read, and the app's request waiting for one. */
const commands = [];
let reader = null;

/** Answers the waiting request: with a command, or with nothing (204). */
function answer(command) {
  const { res, timer } = reader;
  reader = null;
  clearTimeout(timer);
  if (command === undefined) res.writeHead(204).end();
  else res.writeHead(200, { 'content-type': 'text/plain' }).end(command);
}

function relay() {
  if (reader && commands.length > 0) answer(commands.shift());
}

/** One delivery, its links on the host the app asked. */
function delivery(base) {
  served += 1;
  const now = Date.now();
  const videos = (name) => ({
    hevc: `${base}/clips/${name}.mov?token=${served}`,
    stacked: `${base}/clips/${name}.mp4?token=${served}`
  });
  const when = (name, value = true) => [{ input: name, op: '==', value }];
  return {
    deliverySchemaVersion: 1,
    playerContract: 1,
    requires: [],
    target: 'full',
    mode: 'selected',
    release: { id: 'example-release-1' },
    deliveryAccess: {
      urlMode: 'signed',
      signedUrlExpiresAt: new Date(now + lifetimeMs).toISOString(),
      lastFetchedAt: new Date(now).toISOString()
    },
    runtimeGraph: {
      runtimeGraphSchemaVersion: 1,
      version: '2.1',
      name: 'Disc',
      initialNode: 'idle',
      autoPlay: true,
      nodes: [
        { id: 'idle', name: 'Idle' },
        { id: 'working', name: 'Working' }
      ],
      inputs: [
        { name: 'behavior::working', type: 'boolean', default: false },
        { name: 'behavior::celebrate', type: 'trigger', default: false }
      ],
      edges: [
        { id: 'idle', source: 'idle', target: 'idle', isLoop: true, duration: 1, videos: videos('idle') },
        {
          id: 'celebrate',
          source: 'idle',
          target: 'idle',
          isLoop: true,
          duration: 1,
          conditions: when('behavior::celebrate'),
          videos: videos('celebrate')
        },
        {
          id: 'hi',
          source: 'idle',
          target: 'idle',
          isLoop: true,
          duration: 0.8,
          conditions: when('action::click'),
          videos: videos('hi')
        },
        {
          id: 'to-work',
          source: 'idle',
          target: 'working',
          isLoop: false,
          duration: 0.5,
          conditions: when('behavior::working'),
          movement: { dx: 0, dy: -24 },
          videos: videos('to-work')
        },
        { id: 'work', source: 'working', target: 'working', isLoop: true, duration: 1, videos: videos('work') },
        {
          id: 'to-idle',
          source: 'working',
          target: 'idle',
          isLoop: false,
          duration: 0.5,
          conditions: when('behavior::working', false),
          movement: { dx: 0, dy: 24 },
          videos: videos('to-idle')
        }
      ]
    }
  };
}

const types = { '.mov': 'video/quicktime', '.mp4': 'video/mp4' };

createServer((req, res) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host}`);
  console.log(`${new Date().toISOString()} ${req.method} ${url.pathname}${url.search}`);
  if (req.method === 'POST' && url.pathname.startsWith('/do/')) {
    commands.push(url.pathname.slice('/do/'.length));
    relay();
    res.writeHead(202).end();
    return;
  }
  if (url.pathname === '/next') {
    // A newer request replaces the one waiting; each waits 20 seconds at most.
    if (reader) answer();
    const waiting = { res, timer: setTimeout(() => reader === waiting && answer(), 20_000) };
    reader = waiting;
    // The app went away (a reload): commands wait for its next request.
    res.on('close', () => {
      if (reader === waiting) {
        clearTimeout(waiting.timer);
        reader = null;
      }
    });
    relay();
    return;
  }
  if (url.pathname === '/delivery.json') {
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify({ data: { delivery: delivery(`http://${req.headers.host}`) } }));
    return;
  }
  const match = /^\/clips\/([a-z-]+\.(mov|mp4))$/.exec(url.pathname);
  const file = match && join(clips, match[1]);
  if (!file || !existsSync(file)) {
    res.writeHead(404).end();
    return;
  }
  const size = statSync(file).size;
  const headers = { 'content-type': types[`.${match[2]}`], 'accept-ranges': 'bytes' };
  const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? '');
  if (range) {
    const start = range[1] ? Number(range[1]) : Math.max(size - Number(range[2]), 0);
    const end = range[1] && range[2] ? Math.min(Number(range[2]), size - 1) : size - 1;
    if (start > end) {
      // From the end of the file on, as ExoPlayer asks to check that a cached file is whole.
      res.writeHead(416, { 'content-range': `bytes */${size}` }).end();
      return;
    }
    res.writeHead(206, { ...headers, 'content-range': `bytes ${start}-${end}/${size}`, 'content-length': end - start + 1 });
    createReadStream(file, { start, end }).pipe(res);
    return;
  }
  res.writeHead(200, { ...headers, 'content-length': size });
  createReadStream(file).pipe(res);
}).listen(port, '0.0.0.0', () => {
  console.log(`Masko example clips on http://localhost:${port}/delivery.json`);
});
