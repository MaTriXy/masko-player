// Plays the example release (server/serve.mjs) with the calls an app makes:
// set, fire, sound, pause and play, reset and position, and a log of every
// event. The server also relays commands from a terminal, so a test can drive
// it: `curl -X POST localhost:47290/do/fire/celebrate`.

import { MaskoView, type DeliveryInput, type MaskoHandle, type Value } from '@masko/player-react-native';
import { StatusBar } from 'expo-status-bar';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Platform, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

const SERVER =
  process.env.EXPO_PUBLIC_CLIPS_URL ?? (Platform.OS === 'android' ? 'http://10.0.2.2:47290' : 'http://localhost:47290');

async function fetchDelivery(): Promise<DeliveryInput> {
  const response = await fetch(`${SERVER}/delivery.json`);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

function clock(): string {
  return new Date().toISOString().slice(14, 23);
}

export default function App() {
  const mascot = useRef<MaskoHandle>(null);
  const [delivery, setDelivery] = useState<DeliveryInput | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [working, setWorking] = useState(false);
  const [sound, setSound] = useState(false);
  const [paused, setPaused] = useState(false);
  const [pose, setPose] = useState('none');
  const [clip, setClip] = useState('none');
  const [log, setLog] = useState<string[]>([]);

  const note = useCallback((line: string) => {
    // Also in the device log (adb logcat ReactNativeJS:I, or the simulator's log stream).
    console.log(`[masko-example] ${line}`);
    setLog((lines) => [`${clock()} ${line}`, ...lines].slice(0, 16));
  }, []);

  const load = useCallback(() => {
    setFailure(null);
    fetchDelivery().then(setDelivery, (e: unknown) => setFailure(`${SERVER}: ${String(e)}`));
  }, []);

  // A new delivery prop: fresh links of the same release, which the view
  // hands to the player's updateDelivery.
  const reload = useCallback(() => {
    fetchDelivery().then(
      (fresh) => {
        setDelivery(fresh);
        note('delivery prop');
      },
      (e: unknown) => note(`delivery prop failed ${String(e)}`)
    );
  }, [note]);
  useEffect(load, [load]);

  const set = useCallback(
    (name: string, value: Value) => {
      mascot.current?.set(name, value);
      if (name === 'working') setWorking(value === true);
      note(`set ${name} ${value}`);
    },
    [note]
  );

  const fire = useCallback(
    (name: string) => {
      mascot.current?.fire(name);
      note(`fire ${name}`);
    },
    [note]
  );

  const reset = useCallback(() => {
    mascot.current?.reset();
    setWorking(false);
    note('reset');
  }, [note]);

  const showPosition = useCallback(async () => {
    const at = await mascot.current?.position();
    note(`position ${at?.clip ?? 'none'} ${at?.time.toFixed(3)}s`);
  }, [note]);

  // Commands relayed by the server: set/working/true, fire/celebrate, sound/on,
  // pause, play, reset, position, delivery.
  const run = useRef<(command: string) => void>(() => undefined);
  run.current = (command: string) => {
    const [verb, name, value] = command.split('/');
    if (verb === 'set' && name) set(name, value === 'true' ? true : value === 'false' ? false : Number(value));
    if (verb === 'fire' && name) fire(name);
    if (verb === 'sound') setSound(name === 'on');
    if (verb === 'pause') setPaused(true);
    if (verb === 'play') setPaused(false);
    if (verb === 'reset') reset();
    if (verb === 'position') showPosition();
    if (verb === 'delivery') reload();
  };
  useEffect(() => {
    let live = true;
    (async () => {
      while (live) {
        try {
          const response = await fetch(`${SERVER}/next`);
          if (live && response.status === 200) run.current(await response.text());
        } catch {
          await new Promise((wake) => setTimeout(wake, 2000));
        }
      }
    })();
    return () => {
      live = false;
    };
  }, []);

  useEffect(() => {
    if (paused) mascot.current?.pause();
    else mascot.current?.play();
  }, [paused]);

  return (
    <View style={styles.screen}>
      <StatusBar style="dark" />
      <Text style={styles.title}>Masko player</Text>
      <Text style={styles.state}>
        pose {pose} / clip {clip}
      </Text>
      <View style={styles.stage}>
        <Checkerboard />
        {delivery ? (
          <MaskoView
            ref={mascot}
            style={styles.mascot}
            delivery={delivery}
            sound={sound}
            getDelivery={() => {
              note('getDelivery');
              return fetchDelivery();
            }}
            onPose={(e) => {
              setPose(e.pose);
              note(`pose ${e.pose}`);
            }}
            onClip={(e) => {
              setClip(e.clip);
              note(`clip ${e.clip} ${e.kind} x${e.rate}`);
            }}
            onReactionDone={(e) => note(`reactionDone ${e.name} ${e.used ? 'used' : 'unused'}`)}
            onMovement={(e) => note(`movement ${e.edge} ${JSON.stringify(e.movement)} x${e.rate} ${e.seconds}s`)}
            onError={(e) => note(`error ${e.code}${e.detail ? ` ${e.detail}` : ''}`)}
          />
        ) : (
          <Text style={styles.wait} onPress={load}>
            {failure ? `${failure}\nStart the clip server (npm run clips), then tap to retry.` : 'Loading'}
          </Text>
        )}
      </View>
      <View style={styles.buttons}>
        <Button label={working ? 'Working: on' : 'Working: off'} onPress={() => set('working', !working)} />
        <Button label="Celebrate" onPress={() => fire('celebrate')} />
        <Button label={sound ? 'Sound: on' : 'Sound: off'} onPress={() => setSound(!sound)} />
        <Button label={paused ? 'Play' : 'Pause'} onPress={() => setPaused(!paused)} />
        <Button label="Reset" onPress={reset} />
        <Button label="Position" onPress={showPosition} />
      </View>
      <ScrollView style={styles.log}>
        {log.map((line, i) => (
          <Text key={`${i}-${line}`} style={styles.line}>
            {line}
          </Text>
        ))}
      </ScrollView>
    </View>
  );
}

function Button({ label, onPress }: { label: string; onPress: () => void }) {
  return (
    <Pressable style={({ pressed }) => [styles.button, pressed && styles.pressed]} onPress={onPress}>
      <Text style={styles.buttonText}>{label}</Text>
    </Pressable>
  );
}

/** Squares behind the mascot, so its transparency shows. */
function Checkerboard() {
  const squares = [];
  for (let row = 0; row < 8; row++) {
    for (let col = 0; col < 8; col++) {
      if ((row + col) % 2 === 0) {
        squares.push(<View key={`${row}-${col}`} style={[styles.square, { top: row * 30, left: col * 30 }]} />);
      }
    }
  }
  return <View style={StyleSheet.absoluteFill}>{squares}</View>;
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#ffffff', paddingTop: 64, paddingHorizontal: 16 },
  title: { fontSize: 24, fontWeight: '700', color: '#1d1b19' },
  state: { marginTop: 4, fontSize: 14, color: '#686460', fontVariant: ['tabular-nums'] },
  stage: {
    marginTop: 12,
    width: 240,
    height: 240,
    alignSelf: 'center',
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#f7f6f5',
    overflow: 'hidden',
    borderRadius: 12
  },
  square: { position: 'absolute', width: 30, height: 30, backgroundColor: '#e4e0dc' },
  mascot: { width: 220, height: 220 },
  wait: { padding: 16, textAlign: 'center', color: '#686460' },
  buttons: { marginTop: 16, flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  button: { backgroundColor: '#f95d02', borderRadius: 8, paddingVertical: 10, paddingHorizontal: 14 },
  pressed: { opacity: 0.7 },
  buttonText: { color: '#ffffff', fontWeight: '600' },
  log: { marginTop: 16, flex: 1, backgroundColor: '#f7f6f5', borderRadius: 8, padding: 8, marginBottom: 32 },
  line: { fontFamily: Platform.select({ ios: 'Menlo', default: 'monospace' }), fontSize: 12, color: '#1d1b19' }
});
