// A static server for the browser tests: the built package (/dist), the test
// pages (/pages), bundles made for them (/build), generated clips (/clips)
// and downloaded Masko clips (/real). Range requests work as for any media
// host; `?delay=ms` slows a response down, `?status=404` fails it. /moved
// serves the package as a dev server that moved it away from its .wasm
// (Vite pre-bundling): the .wasm is the app's HTML page.
import { createServer } from 'node:http';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, '..', '..');
const roots = {
  dist: join(web, 'dist'),
  moved: join(web, 'dist'),
  pages: join(here, 'pages'),
  build: join(here, '.build'),
  clips: join(here, '.clips'),
  real: join(here, '.cache')
};
const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
  '.webm': 'video/webm',
  '.mov': 'video/quicktime',
  '.png': 'image/png',
  '.wav': 'audio/wav',
  '.mp3': 'audio/mpeg'
};

const port = Number(process.env.PORT ?? 4174);

createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', 'http://localhost');
  const [, top, ...rest] = url.pathname.split('/');
  if (top === 'moved' && url.pathname.endsWith('.wasm')) {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end('<!doctype html><title>An app</title>');
    return;
  }
  const root = roots[top];
  const file = root ? normalize(join(root, ...rest)) : null;
  if (!file || !file.startsWith(root) || !existsSync(file) || statSync(file).isDirectory()) {
    res.writeHead(404, { 'content-type': 'text/plain' }).end('not found');
    return;
  }
  const delay = Number(url.searchParams.get('delay') ?? 0);
  if (delay > 0) await new Promise((r) => setTimeout(r, delay));
  const status = Number(url.searchParams.get('status') ?? 200);
  if (status !== 200) {
    res.writeHead(status, { 'content-type': 'text/plain', 'access-control-allow-origin': '*' }).end('failed');
    return;
  }
  const body = readFileSync(file);
  const headers = {
    'content-type': types[extname(file)] ?? 'application/octet-stream',
    'accept-ranges': 'bytes',
    'access-control-allow-origin': '*',
    'cache-control': 'no-cache'
  };
  const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? '');
  if (range) {
    const start = range[1] ? Number(range[1]) : Math.max(0, body.length - Number(range[2]));
    const end = range[1] && range[2] ? Math.min(Number(range[2]), body.length - 1) : body.length - 1;
    if (start >= body.length) {
      res.writeHead(416, { 'content-range': `bytes */${body.length}` }).end();
      return;
    }
    res.writeHead(206, { ...headers, 'content-range': `bytes ${start}-${end}/${body.length}`, 'content-length': end - start + 1 });
    res.end(body.subarray(start, end + 1));
    return;
  }
  res.writeHead(200, { ...headers, 'content-length': body.length });
  res.end(body);
}).listen(port, () => console.log(`test server on http://localhost:${port}`));
