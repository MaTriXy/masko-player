// The small parts: the clock, the preload cache, file choice, deliveries.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ClipCache } from '../src/cache.ts';
import { PlayClock } from '../src/clock.ts';
import { chooseFiles, preferredFormats, readDelivery, sameRelease, type Delivery, type DeliveryEdge } from '../src/delivery.ts';
import { FakeFiles, settle } from './fakes.ts';

test('play time: whole milliseconds, stopped while paused, resumed where it stopped', () => {
  let t = 1000.4;
  const clock = new PlayClock(() => t);
  assert.equal(clock.now(), 0);
  clock.play();
  t += 250.7;
  assert.equal(clock.now(), 250);
  clock.pause();
  t += 10_000;
  assert.equal(clock.now(), 250);
  clock.play();
  t += 100;
  assert.equal(clock.now(), 350);
});

test('cache: a pose keeps its most important preloads; older poses make room', async () => {
  const files = new FakeFiles();
  const cache = new ClipCache(files, 3);
  cache.nextBatch();
  assert.deepEqual(await Promise.all(['a', 'b', 'c', 'd'].map((k) => cache.preload(k, k))), [true, true, true, false]);
  assert.deepEqual(files.requested, ['a', 'b', 'c'], 'the least important preload of a full pose is skipped');
  cache.nextBatch();
  assert.equal(await cache.preload('e', 'e'), true, 'a new pose evicts the oldest file of an older pose');
  assert.equal(cache.has('a'), false);
  assert.deepEqual(files.freed, ['blob:a']);
  assert.equal(await cache.preload('b', 'b'), true, 'a file kept for the new pose is not loaded again');
  assert.equal(files.requested.filter((u) => u === 'b').length, 1);
});

test('cache: files in use by a slot stay; failures are reported; dropped loads are not failures', async () => {
  const files = new FakeFiles();
  const cache = new ClipCache(files, 1);
  await cache.preload('a', 'a');
  assert.equal(await cache.acquire('a'), 'blob:a');
  cache.nextBatch();
  assert.equal(await cache.preload('b', 'b'), false, 'the only file is on screen: no room');
  cache.release('a');
  assert.equal(await cache.preload('b', 'b'), true);
  files.broken.add('c');
  cache.nextBatch();
  await assert.rejects(cache.preload('c', 'c'));
  assert.equal(cache.has('c'), false);
  files.hold = true;
  cache.nextBatch();
  const d = cache.preload('d', 'd');
  cache.clear();
  files.release();
  assert.equal(await d, false);
  await settle();
});

const edge = (videos: DeliveryEdge['videos']): DeliveryEdge => ({
  id: 'e',
  source: 'a',
  target: 'b',
  isLoop: false,
  duration: 1,
  videos
});

test('file choice: preferred format first, then the other once', () => {
  const e = edge({ webm: 'e.webm', hevc: 'e.mov' });
  assert.deepEqual(chooseFiles(e, ['webm', 'hevc'], 360), [
    { key: 'e|webm', url: 'e.webm' },
    { key: 'e|hevc', url: 'e.mov' }
  ]);
  assert.deepEqual(
    chooseFiles(edge({ hevc: 'e.mov' }), ['webm', 'hevc'], 360).map((f) => f.url),
    ['e.mov']
  );
  assert.deepEqual(chooseFiles(edge(undefined), ['webm'], 360), []);
});

test('file choice: the smallest variant at least as large as the mascot on screen, else the base file', () => {
  const e = edge({
    webm: 'base.webm',
    variants: { '180': { webm: '180.webm' }, '360': { webm: '360.webm', hevc: '360.mov' }, '720': { webm: '720.webm' } }
  });
  const pick = (px: number, formats: ('webm' | 'hevc')[] = ['webm']) => chooseFiles(e, formats, px).map((f) => f.url);
  assert.deepEqual(pick(150), ['180.webm']);
  assert.deepEqual(pick(180), ['180.webm']);
  assert.deepEqual(pick(181), ['360.webm']);
  assert.deepEqual(pick(200 * 2), ['720.webm'], 'size times density');
  assert.deepEqual(pick(1000), ['base.webm']);
  assert.deepEqual(pick(0), ['base.webm'], 'unknown size: the base file');
  assert.deepEqual(pick(100, ['hevc']), ['360.mov']);
  assert.deepEqual(pick(1000, ['hevc']), ['360.mov'], 'no base HEVC: the largest HEVC variant');
});

test('format: HEVC on Safari and every iPhone or iPad browser, WebM elsewhere', () => {
  const ua = {
    safari:
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
    chrome:
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
    edge: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0',
    firefox: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0',
    iosChrome:
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0 Mobile/15E148 Safari/604.1',
    android:
      'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36'
  };
  assert.deepEqual(preferredFormats(ua.safari), ['hevc', 'webm']);
  assert.deepEqual(preferredFormats(ua.iosChrome), ['hevc', 'webm']);
  assert.deepEqual(preferredFormats(ua.safari.replace('Macintosh', 'Macintosh'), 5), ['hevc', 'webm'], 'iPad as Mac');
  for (const name of ['chrome', 'edge', 'firefox', 'android'] as const) {
    assert.deepEqual(preferredFormats(ua[name]), ['webm', 'hevc'], name);
  }
});

test('deliveries: the API response unwraps; a refresh must be the same release', () => {
  const d: Delivery = {
    deliverySchemaVersion: 1,
    runtimeGraph: {
      initialNode: 'a',
      nodes: [{ id: 'a', transparentThumbnailUrl: 'https://x.test/a.png?sig=1' }],
      edges: [{ id: 'l', source: 'a', target: 'a', isLoop: true, duration: 1, videos: { webm: 'https://x.test/l.webm?sig=1' } }]
    }
  };
  assert.equal(readDelivery({ data: { delivery: d } }).delivery, d);
  assert.equal(readDelivery({ delivery: d }).delivery, d);
  assert.deepEqual(readDelivery(JSON.stringify(d)).delivery, d);
  const fresh = JSON.parse(JSON.stringify(d).replaceAll('sig=1', 'sig=2')) as Delivery;
  assert.equal(sameRelease(d, fresh), true);
  const changed = structuredClone(fresh);
  changed.runtimeGraph.edges[0].duration = 2;
  assert.equal(sameRelease(d, changed), false);
});
