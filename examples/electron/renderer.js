// The same two-pose canvas as ../web: public Dumple clips in WebM, which
// Electron's Chromium plays with transparency. A real app gets its release
// delivery from GET /v1/canvases/{canvasId}/releases/{releaseId}/delivery,
// through its own backend (never put the API key in the app).
import { mountMascot } from './node_modules/@masko/player/dist/index.js';

const base = 'https://assets.masko.ai/547bbb8e/dumple-vsa8qdhb/';
const edge = (id, webm, hevc, source, target, conditions = []) => ({
  id,
  source,
  target,
  isLoop: source === target,
  duration: 4.042,
  videos: { webm: `${base}${webm}-360.webm`, hevc: `${base}${hevc}-360.mov` },
  conditions
});

const delivery = {
  deliverySchemaVersion: 1,
  playerContract: 1,
  requires: [],
  target: 'web',
  mode: 'selected',
  runtimeGraph: {
    runtimeGraphSchemaVersion: 1,
    version: '2.1',
    name: 'Dumple',
    initialNode: 'idle',
    autoPlay: true,
    nodes: [
      { id: 'idle', name: 'Idle' },
      { id: 'working', name: 'Working' }
    ],
    inputs: [{ name: 'behavior::working', type: 'boolean', default: false }],
    edges: [
      edge('idle-loop', 'idle-settle-dfce9495', 'idle-settle-86ac92a3', 'idle', 'idle'),
      edge('work-loop', 'laptop-working-dc398b45', 'laptop-working-29387774', 'working', 'working'),
      edge('to-work', 'panic-tremble-7863df85', 'panic-tremble-203e31a8', 'idle', 'working', [
        { input: 'behavior::working' }
      ]),
      edge('to-idle', 'dumpling-groove-9fcd9f24', 'dumpling-groove-1f47051d', 'working', 'idle', [
        { input: 'behavior::working', value: false }
      ])
    ]
  }
};

const element = document.getElementById('mascot');
const mascot = mountMascot(element, { delivery });
for (const name of ['pose', 'clip', 'reactionDone', 'movement', 'error']) {
  mascot.on(name, (event) => console.log(`${name} ${JSON.stringify(event)}`));
}

// The app sends what the person does: a click on Dumple puts him to work, or
// back to rest.
let working = false;
element.addEventListener('click', () => {
  working = !working;
  mascot.set('working', working);
});
