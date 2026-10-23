// The engine, typed. The WebAssembly binding passes commands and state as
// JSON strings (bindings/wasm/src/lib.rs); this file parses them. Every rule
// lives in the engine: nothing here decides what plays.

import init, { initSync, MaskoEngine } from './wasm/masko_player_wasm.js';

export type ClipKind = 'pose' | 'move';

/** What the player must do, in order (spec/player.md, "Commands"). */
export type Command =
  | { type: 'showClip'; edge: string; kind: ClipKind; rate: number }
  | { type: 'showStill'; pose: string }
  | { type: 'preload'; edge: string }
  | { type: 'playSound'; edge: string }
  | { type: 'stopSounds'; onlyLooping: boolean }
  | { type: 'poseEntered'; pose: string }
  | { type: 'interrupted'; edge: string }
  | { type: 'spent'; name: string; used: boolean }
  | { type: 'error'; code: string };

/** The engine's view of the screen, for tests and tools. */
export interface EngineState {
  clock: number;
  pose: string | null;
  /** The edge on screen, or `still:<pose>`. */
  clip: string | null;
  moving: boolean;
  shownAt: number;
  expectedMs: number;
  next: { clip: string; at: number | 'end' } | null;
}

export type Value = boolean | number;

/** Where the WebAssembly comes from: a URL, its bytes, or a compiled module. */
export type WasmSource = string | URL | Response | BufferSource | WebAssembly.Module;

/** A delivery the engine refuses (rules.md 1.2, 1.3). */
export class LoadError extends Error {
  readonly code: string;
  readonly detail: string;
  constructor(code: string, detail: string) {
    super(detail ? `${code}: ${detail}` : code);
    this.name = 'LoadError';
    this.code = code;
    this.detail = detail;
  }
}

let wasmSource: WasmSource | undefined;
let ready: Promise<void> | null = null;

/**
 * Where to load the engine's WebAssembly from. By default the ES module build
 * loads `masko_player_wasm_bg.wasm` next to itself and the script build has it
 * inlined. Call before the first mascot mounts.
 */
export function setWasmSource(source: WasmSource): void {
  wasmSource = source;
  ready = null;
}

/** Loads the engine once; every mascot on the page shares it. */
export function loadWasm(): Promise<void> {
  if (!ready) {
    const source = wasmSource;
    ready = init(source === undefined ? undefined : { module_or_path: source }).then(
      () => undefined,
      (error: unknown) => {
        ready = null;
        throw error;
      }
    );
  }
  return ready;
}

/** Loads the engine from bytes at once, for Node and tests. */
export function loadWasmSync(bytes: BufferSource | WebAssembly.Module): void {
  initSync({ module: bytes });
  ready = Promise.resolve();
}

function commands(json: string): Command[] {
  return JSON.parse(json) as Command[];
}

/** One loaded release. Times are play time in whole milliseconds. */
export class Engine {
  private readonly inner: MaskoEngine;

  private constructor(inner: MaskoEngine) {
    this.inner = inner;
  }

  /** Reads a delivery (a JSON string), or throws a `LoadError`. */
  static load(delivery: string): Engine {
    try {
      return new Engine(new MaskoEngine(delivery));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const match = /^([a-z_]+): ?([\s\S]*)$/.exec(message);
      throw match ? new LoadError(match[1], match[2]) : new LoadError('unreadable', message);
    }
  }

  start(now: number): Command[] {
    return commands(this.inner.start(now));
  }

  reset(now: number): Command[] {
    return commands(this.inner.reset(now));
  }

  set(name: string, value: Value, now: number): Command[] {
    return commands(this.inner.set(name, value, now));
  }

  fire(name: string, now: number): Command[] {
    return commands(this.inner.fire(name, now));
  }

  click(now: number): Command[] {
    return commands(this.inner.click(now));
  }

  hover(on: boolean, now: number): Command[] {
    return commands(this.inner.hover(on, now));
  }

  advance(now: number): Command[] {
    return commands(this.inner.advance(now));
  }

  /** The clip's first frame is on screen: its safety net counts from now (rules.md 9.3). */
  clipShown(edge: string, now: number): Command[] {
    return commands(this.inner.clipShown(edge, now));
  }

  clipEnded(edge: string, now: number): Command[] {
    return commands(this.inner.clipEnded(edge, now));
  }

  clipFailed(edge: string, now: number): Command[] {
    return commands(this.inner.clipFailed(edge, now));
  }

  markUnplayable(edge: string): void {
    this.inner.markUnplayable(edge);
  }

  markPlayable(edge: string): void {
    this.inner.markPlayable(edge);
  }

  previewShowPose(pose: string, now: number): Command[] {
    return commands(this.inner.previewShowPose(pose, now));
  }

  previewPlayMove(edge: string, now: number): Command[] {
    return commands(this.inner.previewPlayMove(edge, now));
  }

  /** The next play time at which the engine has work, if any. */
  nextWake(): number | undefined {
    return this.inner.nextWake();
  }

  state(): EngineState {
    return JSON.parse(this.inner.state()) as EngineState;
  }

  value(name: string): Value {
    return this.inner.value(name) as Value;
  }

  pendingFires(): string[] {
    return this.inner.pendingFires();
  }

  seed(seed: number): void {
    this.inner.seed(seed);
  }

  /** Fixed extra-clip rolls, for scenarios. */
  useRolls(rolls: number[]): void {
    this.inner.useRolls(Float64Array.from(rolls));
  }

  free(): void {
    this.inner.free();
  }
}
