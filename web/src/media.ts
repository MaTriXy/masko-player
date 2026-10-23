// What the player needs from the page, as small interfaces: the DOM gives the
// real ones (dom.ts) and the tests give fakes.

import type { Format } from './delivery.ts';

/** One of the two persistent, stacked video slots. Always muted unless told. */
export interface VideoSlot {
  /** The source loaded now, or null. */
  readonly src: string | null;
  /** Clip time of the frame on screen, in seconds of the file. */
  readonly time: number;
  /** Loads `src` from its first frame; the same `src` again seeks to 0. */
  load(src: string): void;
  /** Plays at `rate`. Rejects with the browser's error: `NotAllowedError` when autoplay is blocked. */
  play(rate: number, muted: boolean): Promise<void>;
  pause(): void;
  /** Shows or hides the slot at once, with no transition. */
  setVisible(on: boolean): void;
  /** Calls `fn` once, when a frame of the loaded file is decoded and about to be shown. */
  onFrame(fn: () => void): () => void;
  /** Calls `fn` once, when the loaded file has its first frame, playing or not. */
  onReady(fn: () => void): () => void;
  /** Calls `fn` each time the loaded file plays to its end. */
  onEnded(fn: () => void): () => void;
  /** Calls `fn` when the loaded file cannot load or decode. */
  onError(fn: () => void): () => void;
  /** Drops the loaded source. */
  unload(): void;
}

/** The image a pose shows when it has no clip that plays (rules.md 7.4). */
export interface StillLayer {
  /** Loads and decodes the image without showing it. */
  load(url: string): Promise<void>;
  setVisible(on: boolean): void;
}

export interface Sound {
  stop(): void;
  pause(): void;
  resume(): void;
  /** Calls `fn` once when a one-shot sound finishes. */
  onEnded(fn: () => void): void;
}

export interface SoundOut {
  play(url: string, volume: number, loop: boolean): Sound;
}

/** Loads whole files for the preload cache. */
export interface FileLoader {
  /** Resolves with a source a slot can load at once. */
  load(url: string, signal: AbortSignal): Promise<string>;
  /** Frees a source `load` returned. */
  free(src: string): void;
}

export interface Host {
  /** A monotonic clock in milliseconds. */
  now(): number;
  /** Wall-clock milliseconds, for link expiry. */
  wallNow(): number;
  setTimer(fn: () => void, ms: number): unknown;
  clearTimer(id: unknown): void;
  slots: [VideoSlot, VideoSlot];
  still: StillLayer;
  sounds: SoundOut;
  files: FileLoader;
  /** Formats in order of preference. */
  formats: Format[];
  /** The mascot's size on screen times the screen density, in pixels. */
  pixels(): number;
  /** Shows or hides the tap-to-play overlay. */
  blocked(on: boolean): void;
  /** The player is destroyed: remove what the host added. */
  dispose(): void;
}
