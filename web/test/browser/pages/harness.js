// Shared by the test pages: the test canvas over the generated clips, an
// event recorder and a per-frame sampler of what is on screen.

const CLIP = (id, query = '') => `${location.origin}/clips/${id}.webm${query}`;

/** Colours of the generated clips, to tell from a frame which clip shows. */
export const PALETTE = {
  'idle-loop': [249, 93, 2],
  'work-loop': [34, 170, 68],
  'to-work': [34, 85, 238],
  'to-idle': [153, 51, 204],
  poke: [238, 204, 0]
};

/**
 * The test canvas: idle and working, a move each way on `behavior::working`,
 * and a poke on `action::click`. `query` adds a query string per clip (`?delay=600`),
 * `broken` lists clips whose WebM fails (their `hevc` is a WebM that plays),
 * `dead` clips whose files all fail, `version` a query string on every clip
 * (new links for the same release), `name` the canvas name (another name is
 * another release). `hum` gives the idle loop a looping sound, `tick` the
 * working loop a one-shot sound.
 */
export function testDelivery({
  autoPlay = true,
  query = {},
  broken = [],
  dead = [],
  sound = false,
  version = '',
  name = 'Test bot',
  hum = false,
  tick = false
} = {}) {
  const videos = (id) => {
    const q = query[id] ?? version;
    if (dead.includes(id)) return { webm: CLIP(id, '?status=404'), hevc: CLIP(id, '?status=404&f=mov') };
    return broken.includes(id)
      ? { webm: CLIP(id, '?status=404'), hevc: CLIP(id, q) }
      : { webm: CLIP(id, q), hevc: `${location.origin}/clips/${id}.mov` };
  };
  const edge = (id, source, target, duration, extra = {}) => ({
    id,
    source,
    target,
    isLoop: source === target,
    duration,
    videos: videos(id),
    ...extra
  });
  return {
    deliverySchemaVersion: 1,
    playerContract: 1,
    requires: ['any-state'],
    target: 'web',
    mode: 'selected',
    runtimeGraph: {
      runtimeGraphSchemaVersion: 1,
      version: '2.1',
      name,
      initialNode: 'idle',
      autoPlay,
      nodes: [
        { id: 'idle', name: 'Idle', transparentThumbnailUrl: `${location.origin}/clips/idle.png` },
        { id: 'working', name: 'Working' }
      ],
      inputs: [{ name: 'behavior::working', type: 'boolean', default: false }],
      edges: [
        edge('idle-loop', 'idle', 'idle', 2, hum ? { sound: { url: `${location.origin}/clips/tick.wav?hum`, loop: true } } : {}),
        edge('work-loop', 'working', 'working', 2, tick ? { sound: { url: `${location.origin}/clips/tick.wav?tick` } } : {}),
        edge('to-work', 'idle', 'working', 1, {
          conditions: [{ input: 'behavior::working' }],
          movement: { x: 40 },
          ...(sound ? { sound: { url: `${location.origin}/clips/tick.wav`, volume: 0.2 } } : {})
        }),
        edge('to-idle', 'working', 'idle', 1, { conditions: [{ input: 'behavior::working', value: false }] }),
        edge('poke', 'idle', 'working', 1, { conditions: [{ input: 'action::click' }] })
      ]
    }
  };
}

/** Records every player event with its time. */
export function record(handle) {
  const events = [];
  for (const name of ['pose', 'clip', 'reactionDone', 'movement', 'error']) {
    handle.on(name, (e) => events.push({ event: name, t: Math.round(performance.now()), ...e }));
  }
  return events;
}

function nearest(rgb) {
  let best = null;
  let bestD = Infinity;
  for (const [id, c] of Object.entries(PALETTE)) {
    const d = (c[0] - rgb[0]) ** 2 + (c[1] - rgb[1]) ** 2 + (c[2] - rgb[2]) ** 2;
    if (d < bestD) [best, bestD] = [id, d];
  }
  return best;
}

/**
 * Samples the mascot at every animation frame: which slots are visible,
 * whether the visible one has presented a frame of its file, and what the
 * frame shows (opaque pixels and the nearest clip colour).
 */
export function watch(root) {
  const samples = [];
  const videos = [...root.querySelectorAll('video')];
  const presented = new Map(videos.map((v) => [v, 0]));
  // A test may hide the frame callback from the player; the sampler keeps it.
  const rvfc = HTMLVideoElement.prototype.hiddenFrameCallback ?? HTMLVideoElement.prototype.requestVideoFrameCallback;
  for (const v of videos) {
    const reset = () => presented.set(v, 0);
    v.addEventListener('loadstart', reset);
    v.addEventListener('emptied', reset);
    const count = () => {
      presented.set(v, presented.get(v) + 1);
      rvfc.call(v, count);
    };
    rvfc.call(v, count);
  }
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 24;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  let on = true;
  const tick = () => {
    if (!on) return;
    const visible = videos.filter((v) => v.dataset.visible === 'true');
    const still = root.querySelector('img.masko-still[data-visible="true"]');
    const s = {
      t: Math.round(performance.now()),
      visible: visible.map((v) => v.dataset.slot),
      still: !!still,
      ready: visible.map((v) => v.readyState),
      presented: visible.map((v) => presented.get(v)),
      src: visible.map((v) => v.currentSrc.split('/').pop()),
      time: visible.map((v) => v.currentTime),
      opaque: 0,
      color: null
    };
    const shown = visible.length === 1 ? visible[0] : still;
    if (shown) {
      ctx.clearRect(0, 0, 24, 24);
      ctx.drawImage(shown, 0, 0, 24, 24);
      const px = ctx.getImageData(0, 0, 24, 24).data;
      const sum = [0, 0, 0];
      for (let i = 0; i < px.length; i += 4) {
        if (px[i + 3] > 128) {
          s.opaque++;
          sum[0] += px[i];
          sum[1] += px[i + 1];
          sum[2] += px[i + 2];
        }
      }
      if (s.opaque) s.color = nearest(sum.map((x) => x / s.opaque));
    }
    samples.push(s);
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
  return { samples, stop: () => (on = false) };
}
