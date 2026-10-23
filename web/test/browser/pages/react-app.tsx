// The React test page: <MaskoPlayer> with a ref and event props.
import { StrictMode, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { setWasmSource, type MaskoHandle } from '@masko/player';
import { MaskoPlayer } from '@masko/player/react';
// @ts-expect-error plain JavaScript test helper
import { testDelivery } from '/pages/harness.js';

// Bundled into another folder than dist/: say where the engine is.
setWasmSource('/dist/masko_player_wasm_bg.wasm');

type Log = { event: string; [key: string]: unknown }[];
const log: Log = [];
const w = window as unknown as {
  events: Log;
  mascot: MaskoHandle | null;
  ready: boolean;
  setDelivery: (d: unknown) => void;
  testDelivery: typeof testDelivery;
};
w.events = log;
w.testDelivery = testDelivery;

function App() {
  const ref = useRef<MaskoHandle>(null);
  const [delivery, setDelivery] = useState(() => testDelivery());
  w.setDelivery = setDelivery;
  return (
    <MaskoPlayer
      ref={(h) => {
        ref.current = h;
        w.mascot = h;
      }}
      delivery={delivery}
      style={{ width: 240, height: 240 }}
      onPose={(e) => log.push({ event: 'pose', ...e })}
      onClip={(e) => log.push({ event: 'clip', ...e })}
      onMovement={(e) => log.push({ event: 'movement', ...e })}
      onReactionDone={(e) => log.push({ event: 'reactionDone', ...e })}
      onError={(e) => log.push({ event: 'error', ...e })}
    />
  );
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
w.ready = true;
