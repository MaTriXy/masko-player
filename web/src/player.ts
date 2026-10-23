// The player around the engine (spec/player.md): one play-time clock, one
// wake timer, two persistent video slots, a still, sounds and a preload
// cache. It carries out the engine's commands and reports what the video
// does; it never decides what plays.

import { ClipCache } from './cache.ts';
import { PlayClock } from './clock.ts';
import {
  chooseFiles,
  expiresAt,
  indexDelivery,
  readDelivery,
  sameRelease,
  type Delivery,
  type DeliveryEdge,
  type DeliveryInput,
  type DeliveryNode,
  type FileChoice
} from './delivery.ts';
import { Engine, LoadError, loadWasm, type ClipKind, type Command, type Value } from './engine.ts';
import type { Host, Sound } from './media.ts';

/** What the app hears (spec/player.md, "What the app sees"). */
export interface MaskoEvents {
  /** The mascot entered a pose. */
  pose: { pose: string };
  /** A clip, or a pose's still (`still:<pose>`), is now on screen. */
  clip: { clip: string; kind: ClipKind | 'still'; rate: number };
  /** A fire is done: used by a start, or spent unused. `name` is the full name, as `action::boop`. */
  reactionDone: { name: string; used: boolean };
  /** A move with `movement` is now on screen: the app may move the mascot. */
  movement: { edge: string; movement: unknown; rate: number; seconds: number };
  /** Something went wrong, with a code from rules.md or the player. */
  error: { code: string; detail?: string };
}

export type MaskoEventName = keyof MaskoEvents;
export type MaskoListener<K extends MaskoEventName> = (event: MaskoEvents[K]) => void;

export interface PlayerOptions {
  /** The release delivery, its JSON, or the API response around it. */
  delivery: DeliveryInput;
  /** Returns a fresh delivery of the same release, for signed links that expire. */
  getDelivery?: () => DeliveryInput | Promise<DeliveryInput>;
  /** Lets clips with their own voice (`hasAudio`) be heard. Off by default. */
  sound?: boolean;
  /** Starts at once. Defaults to the canvas's `autoPlay`, else true. */
  autoPlay?: boolean;
  /** Seeds the extra-clip rolls; random by default. */
  seed?: number;
}

/** The clip on screen and its clip time, in seconds of its file. */
export interface Position {
  clip: string | null;
  time: number;
}

type Call = (now: number) => Command[];
type Hold = 'app' | 'blocked' | 'hidden';

/** One showing of one clip in one slot. */
interface Showing {
  edge: string;
  kind: ClipKind;
  rate: number;
  slot: 0 | 1;
  /** The show command it answers (`showToken`); 0 when the engine did not ask for it. */
  ask: number;
  files: FileChoice[];
  tried: number;
  muted: boolean;
  /** Its end was reported for this loop. */
  ended: boolean;
  cancelled: boolean;
  off: (() => void)[];
}

type Screen = { type: 'clip'; showing: Showing } | { type: 'still'; pose: string } | { type: 'none' };

/** Retry delay after a failed refresh, and the soonest a refresh repeats. */
const REFRESH_RETRY_MS = 30_000;
/** Refresh this long before signed links expire, or halfway when they expire sooner than twice this. */
const REFRESH_LEAD_MS = 5 * 60_000;

export class Player {
  private readonly host: Host;
  private readonly options: PlayerOptions;
  private readonly clock: PlayClock;
  private readonly cache: ClipCache;
  private readonly listeners = new Map<MaskoEventName, Set<(event: never) => void>>();

  private delivery: Delivery | null = null;
  private json = '';
  private edges = new Map<string, DeliveryEdge>();
  private nodes = new Map<string, DeliveryNode>();
  private engine: Engine | null = null;

  private started = false;
  private wantStart: boolean | null = null;
  private destroyed = false;
  /** The delivery was refused: nothing plays and calls are dropped. */
  private refused = false;
  private readonly holds = new Set<Hold>();
  private queue: Call[] = [];
  private wakeTimer: unknown = null;
  private refreshTimer: unknown = null;

  private screen: Screen = { type: 'none' };
  private pending: Showing | null = null;
  /** Counts show commands: a still or a `clipShown` report that a later one overtook is stale. */
  private showToken = 0;
  /** A pose clip restarted in place by the commands running now, reported shown after them. */
  private restarted: Showing | null = null;
  private readonly slotKeys: [string | null, string | null] = [null, null];
  private sounds: { sound: Sound; loop: boolean }[] = [];
  /** Edges the engine was told cannot play. */
  private readonly unplayable = new Set<string>();
  /** Files that failed to load, tried last until the links are refreshed. */
  private readonly failedKeys = new Set<string>();
  private voices: boolean;

  readonly preview = {
    /** Editors and tools: cut to a pose at once (rules.md 13). */
    showPose: (pose: string): void => this.call((now) => this.engine!.previewShowPose(pose, now)),
    /** Editors and tools: play one move from the current pose (rules.md 13). */
    playMove: (edge: string): void => this.call((now) => this.engine!.previewPlayMove(edge, now))
  };

  constructor(host: Host, options: PlayerOptions) {
    this.host = host;
    this.options = options;
    this.clock = new PlayClock(() => host.now());
    this.cache = new ClipCache(host.files);
    this.voices = options.sound ?? false;
    try {
      const { delivery, json } = readDelivery(options.delivery);
      this.useDelivery(delivery);
      this.json = json;
    } catch (error) {
      this.refused = true;
      this.later(() => this.emit('error', { code: 'unreadable', detail: message(error) }));
      return;
    }
    if (options.autoPlay !== undefined) this.wantStart = options.autoPlay;
    void this.boot();
  }

  // ------------------------------------------------------------- app calls

  set(name: string, value: Value): void {
    if (typeof value !== 'boolean' && typeof value !== 'number') {
      this.later(() => this.emit('error', { code: 'bad_value', detail: `set(${name}) takes a boolean or a number` }));
      return;
    }
    this.call((now) => this.engine!.set(name, value, now));
  }

  fire(name: string): void {
    this.call((now) => this.engine!.fire(name, now));
  }

  /** The person clicked the mascot. Ignored while the mascot is not playing. */
  click(): void {
    if (this.running()) this.call((now) => this.engine!.click(now));
  }

  /** The pointer entered or left the mascot. */
  hover(on: boolean): void {
    this.call((now) => this.engine!.hover(on, now));
  }

  reset(): void {
    this.call((now) => this.engine!.reset(now));
  }

  /** Starts the mascot, or resumes it where it stopped. */
  play(): void {
    if (this.destroyed) return;
    if (!this.started) {
      this.wantStart = true;
      if (this.engine) this.start();
      return;
    }
    this.host.blocked(false);
    this.holds.delete('blocked');
    this.setHold('app', false);
  }

  /** Stops play time, clips, timers and sounds; `set` and `fire` wait for `play`. */
  pause(): void {
    if (this.destroyed) return;
    if (!this.started) {
      this.wantStart = false;
      return;
    }
    this.setHold('app', true);
  }

  /** The page is hidden or shown again: play time stops while hidden. */
  setHidden(hidden: boolean): void {
    if (!this.destroyed) this.setHold('hidden', hidden);
  }

  /** Lets clip voices be heard, from the next clip on. */
  setSound(on: boolean): void {
    this.voices = on;
  }

  position(): Position {
    const s = this.screen;
    if (s.type === 'clip') return { clip: s.showing.edge, time: this.host.slots[s.showing.slot].time };
    if (s.type === 'still') return { clip: `still:${s.pose}`, time: 0 };
    return { clip: null, time: 0 };
  }

  on<K extends MaskoEventName>(name: K, listener: MaskoListener<K>): () => void {
    let set = this.listeners.get(name);
    if (!set) this.listeners.set(name, (set = new Set()));
    set.add(listener as (event: never) => void);
    return () => set.delete(listener as (event: never) => void);
  }

  /** Swaps in a fresh delivery of the same release: its URLs only. */
  updateDelivery(input: DeliveryInput): boolean {
    if (this.destroyed || !this.delivery) return false;
    let fresh: Delivery;
    try {
      fresh = readDelivery(input).delivery;
    } catch (error) {
      this.emit('error', { code: 'refresh_failed', detail: message(error) });
      return false;
    }
    if (!sameRelease(this.delivery, fresh)) {
      this.emit('error', { code: 'refresh_mismatch', detail: 'getDelivery returned another release' });
      return false;
    }
    this.useDelivery(fresh);
    this.failedKeys.clear();
    // Clips that failed on expired links may load now.
    for (const edge of [...this.unplayable]) this.preload(edge);
    this.scheduleRefresh();
    return true;
  }

  destroy(): void {
    if (this.destroyed) return;
    this.destroyed = true;
    this.cancelWake();
    if (this.refreshTimer !== null) this.host.clearTimer(this.refreshTimer);
    this.refreshTimer = null;
    for (const s of this.sounds) s.sound.stop();
    this.sounds = [];
    if (this.pending) this.cancel(this.pending);
    if (this.screen.type === 'clip') this.cancel(this.screen.showing);
    this.pending = null;
    this.screen = { type: 'none' };
    for (const slot of this.host.slots) {
      slot.pause();
      slot.setVisible(false);
      slot.unload();
    }
    this.host.still.setVisible(false);
    this.cache.clear();
    this.engine?.free();
    this.engine = null;
    this.queue = [];
    this.listeners.clear();
    this.host.dispose();
  }

  /** The canvas's click effect (rules.md 14). */
  clickEffect(): string | undefined {
    return this.delivery?.runtimeGraph?.clickEffect;
  }

  // ------------------------------------------------------------- engine

  private async boot(): Promise<void> {
    try {
      await loadWasm();
    } catch (error) {
      if (!this.destroyed) this.emit('error', { code: 'engine_unavailable', detail: message(error) });
      return;
    }
    if (this.destroyed) return;
    try {
      this.engine = Engine.load(this.json);
    } catch (error) {
      const e = error instanceof LoadError ? error : new LoadError('unreadable', message(error));
      this.refused = true;
      this.queue = [];
      this.emit('error', { code: e.code, detail: e.detail });
      return;
    }
    this.engine.seed(this.options.seed ?? Math.floor(Math.random() * 2 ** 52) + 1);
    // Values set or fired before the start, at play time 0 (rules.md 11.1).
    const early = this.queue;
    this.queue = [];
    for (const call of early) this.exec(call(0));
    const autoPlay = this.wantStart ?? this.delivery?.runtimeGraph.autoPlay ?? true;
    if (autoPlay) this.start();
    else this.showFirstFrame();
    this.scheduleRefresh();
  }

  private start(): void {
    if (this.started || this.destroyed || !this.engine) return;
    this.started = true;
    if (this.holds.size === 0) this.clock.play();
    this.exec(this.engine.start(0));
    this.sync();
  }

  /** With `autoPlay` false: the first pose's first frame, from a throwaway engine. */
  private showFirstFrame(): void {
    let probe: Engine;
    try {
      probe = Engine.load(this.json);
    } catch {
      return;
    }
    const first = probe.start(0).find((c) => c.type === 'showClip' || c.type === 'showStill');
    probe.free();
    if (first) this.run(first);
    // The engine that plays did not ask for it: its first frame is not reported.
    if (this.pending) this.pending.ask = 0;
  }

  private running(): boolean {
    return this.started && !this.destroyed && this.holds.size === 0;
  }

  /** Runs an engine call now, or keeps it for when the mascot plays. */
  private call(fn: Call): void {
    if (this.destroyed || this.refused) return;
    if (!this.engine || (this.started && !this.running())) {
      this.queue.push(fn);
      return;
    }
    this.exec(fn(this.started ? this.clock.now() : 0));
  }

  private exec(commands: Command[]): void {
    for (const c of commands) {
      if (this.destroyed) return;
      this.run(c);
    }
    // A pose clip restarted in place is on screen at once, after the commands that restarted it.
    const restarted = this.restarted;
    this.restarted = null;
    if (restarted) this.reportShown(restarted);
    this.scheduleWake();
  }

  private run(c: Command): void {
    switch (c.type) {
      case 'showClip':
        this.showClip(c.edge, c.kind, c.rate);
        break;
      case 'showStill':
        this.showStill(c.pose);
        break;
      case 'preload':
        this.preload(c.edge);
        break;
      case 'playSound':
        this.playSound(c.edge);
        break;
      case 'stopSounds':
        this.stopSounds(c.onlyLooping);
        break;
      case 'poseEntered':
        this.cache.nextBatch();
        this.emit('pose', { pose: c.pose });
        break;
      case 'interrupted':
        // The next showClip replaces the move on screen.
        break;
      case 'spent':
        this.emit('reactionDone', { name: c.name, used: c.used });
        break;
      case 'error':
        if (c.code === 'clip_timeout' && this.pending) {
          // The clip asked for did not show in time and the engine counts it unplayable
          // (rules.md 9.3): drop it, and let a later preload of its file mark it playable.
          this.unplayable.add(this.pending.edge);
          this.dropPending();
        }
        this.emit('error', { code: c.code });
        break;
    }
  }

  // ------------------------------------------------------------- clock

  private scheduleWake(): void {
    this.cancelWake();
    if (!this.running() || !this.engine) return;
    const at = this.engine.nextWake();
    if (at === undefined) return;
    this.wakeTimer = this.host.setTimer(() => {
      this.wakeTimer = null;
      this.call((now) => this.engine!.advance(now));
    }, Math.max(0, at - this.clock.now()));
  }

  private cancelWake(): void {
    if (this.wakeTimer !== null) this.host.clearTimer(this.wakeTimer);
    this.wakeTimer = null;
  }

  private setHold(hold: Hold, on: boolean): void {
    if (on) this.holds.add(hold);
    else this.holds.delete(hold);
    this.sync();
  }

  /** Brings the clock, clips and sounds in line with the holds. */
  private sync(): void {
    if (!this.started || this.destroyed) return;
    if (this.running()) {
      if (this.clock.running) return;
      this.clock.play();
      // Calls kept while paused first, then the clips and sounds go on.
      const queued = this.queue;
      this.queue = [];
      for (const call of queued) {
        if (this.running()) this.exec(call(this.clock.now()));
        else this.queue.push(call);
      }
      if (!this.running()) return;
      const screen = this.screen;
      if (screen.type === 'clip' && !screen.showing.ended) this.playShowing(screen.showing);
      if (this.pending) this.playShowing(this.pending);
      for (const s of this.sounds) s.sound.resume();
      this.scheduleWake();
    } else {
      if (!this.clock.running) return;
      this.clock.pause();
      this.cancelWake();
      if (this.screen.type === 'clip') this.host.slots[this.screen.showing.slot].pause();
      if (this.pending) {
        const p = this.pending;
        this.host.slots[p.slot].pause();
        // Shows its first frame while paused.
        p.off.push(this.host.slots[p.slot].onReady(() => this.swapIn(p)));
      }
      for (const s of this.sounds) s.sound.pause();
    }
  }

  // ------------------------------------------------------------- clips

  private showClip(edge: string, kind: ClipKind, rate: number): void {
    this.showToken++;
    const screen = this.screen;
    if (
      kind === 'pose' &&
      screen.type === 'clip' &&
      screen.showing.edge === edge &&
      screen.showing.kind === 'pose' &&
      !screen.showing.cancelled
    ) {
      // The next loop of the clip on screen: restart it, no swap.
      if (this.pending) this.dropPending();
      const s = screen.showing;
      s.ask = this.showToken;
      s.ended = false;
      s.rate = rate;
      this.restarted = s;
      this.host.slots[s.slot].load(this.host.slots[s.slot].src ?? s.files[s.tried].url);
      if (this.running()) this.playShowing(s);
      this.emit('clip', { clip: edge, kind, rate });
      return;
    }
    const busy = screen.type === 'clip' ? screen.showing.slot : null;
    if (this.pending) this.dropPending();
    const files = chooseFiles(this.edges.get(edge), this.host.formats, this.host.pixels());
    files.sort((a, b) => Number(this.failedKeys.has(a.key)) - Number(this.failedKeys.has(b.key)));
    const s: Showing = {
      edge,
      kind,
      rate,
      slot: busy === 0 ? 1 : 0,
      ask: this.showToken,
      files,
      tried: 0,
      muted: !(this.voices && this.edges.get(edge)?.hasAudio === true),
      ended: false,
      cancelled: false,
      off: []
    };
    this.pending = s;
    void this.load(s);
  }

  private async load(s: Showing): Promise<void> {
    const file = s.files[s.tried];
    if (!file) {
      this.fail(s, s.tried);
      return;
    }
    const slot = this.host.slots[s.slot];
    let src = file.url;
    const cached = this.cache.acquire(file.key);
    if (cached) {
      try {
        src = await cached;
      } catch {
        src = file.url;
      }
      if (s.cancelled || this.destroyed) {
        this.cache.release(file.key);
        return;
      }
    }
    const previous = this.slotKeys[s.slot];
    if (previous !== null) this.cache.release(previous);
    this.slotKeys[s.slot] = cached ? file.key : null;
    slot.load(src);
    const attempt = s.tried;
    s.off.push(
      slot.onFrame(() => this.swapIn(s)),
      slot.onEnded(() => this.ended(s)),
      slot.onError(() => this.fail(s, attempt))
    );
    if (this.running()) this.playShowing(s);
    else s.off.push(slot.onReady(() => this.swapIn(s)));
  }

  private playShowing(s: Showing): void {
    const slot = this.host.slots[s.slot];
    const attempt = s.tried;
    slot.play(s.rate, s.muted).catch((error: unknown) => {
      if (s.cancelled || this.destroyed || attempt !== s.tried) return;
      const name = error instanceof Error || isDomError(error) ? (error as { name: string }).name : '';
      if (name === 'AbortError') return;
      if (name === 'NotAllowedError') {
        if (!s.muted) {
          // The browser refuses sound without a gesture: play muted.
          s.muted = true;
          if (this.running()) this.playShowing(s);
          return;
        }
        // Autoplay is blocked: the first frame with a tap-to-play overlay.
        this.host.blocked(true);
        this.setHold('blocked', true);
        return;
      }
      this.fail(s, attempt);
    });
  }

  /** The showing's first frame is decoded: make it visible and hide the old one, in one frame. */
  private swapIn(s: Showing): void {
    if (this.pending !== s || s.cancelled || this.destroyed) return;
    this.pending = null;
    const old = this.screen;
    this.host.slots[s.slot].setVisible(true);
    if (old.type === 'clip') {
      const o = old.showing;
      this.host.slots[o.slot].setVisible(false);
      this.host.slots[o.slot].pause();
      this.detach(o);
      o.cancelled = true;
    } else if (old.type === 'still') {
      this.host.still.setVisible(false);
    }
    this.screen = { type: 'clip', showing: s };
    if (this.unplayable.delete(s.edge)) this.engine?.markPlayable(s.edge);
    this.emit('clip', { clip: s.edge, kind: s.kind, rate: s.rate });
    const edge = this.edges.get(s.edge);
    if (s.kind === 'move' && edge?.movement !== undefined) {
      this.emit('movement', { edge: s.edge, movement: edge.movement, rate: s.rate, seconds: edge.duration / s.rate });
    }
    this.reportShown(s);
  }

  /**
   * Tells the engine the showing's first frame is on screen, at the play time
   * of now (rules.md 9.3). Called once per showing: at the swap, or after a
   * pose clip restarts in place. A showing a later show command overtook is
   * not reported, also when the report waits for play to resume.
   */
  private reportShown(s: Showing): void {
    const ask = s.ask;
    const current = () => ask === this.showToken && !s.cancelled;
    if (!current()) return;
    this.call((now) => (current() ? this.engine!.clipShown(s.edge, now) : []));
  }

  private ended(s: Showing): void {
    if (s.cancelled || s.ended || this.destroyed) return;
    // A clip that ends before its frame callback is on screen by now.
    if (this.pending === s) this.swapIn(s);
    if (this.screen.type !== 'clip' || this.screen.showing !== s) return;
    s.ended = true;
    this.call((now) => this.engine!.clipEnded(s.edge, now));
  }

  /** The file of this attempt failed: try the other format once, then report the clip failed. */
  private fail(s: Showing, attempt: number): void {
    // The error event and the play() refusal can both report one attempt.
    if (s.cancelled || this.destroyed || attempt !== s.tried) return;
    this.detach(s);
    const file = s.files[s.tried];
    if (file) this.failedKeys.add(file.key);
    s.tried++;
    // A file that fails before it is shown: the other format, in the same hidden slot.
    if (this.pending === s && s.tried < s.files.length) {
      void this.load(s);
      return;
    }
    s.cancelled = true;
    if (this.pending === s) this.pending = null;
    this.unplayable.add(s.edge);
    this.call((now) => this.engine!.clipFailed(s.edge, now));
  }

  private showStill(pose: string): void {
    const token = ++this.showToken;
    if (this.pending) this.dropPending();
    const url = this.nodes.get(pose)?.transparentThumbnailUrl;
    const reveal = (shown: boolean) => {
      if (token !== this.showToken || this.destroyed) return;
      this.host.still.setVisible(shown);
      if (this.screen.type === 'clip') {
        const o = this.screen.showing;
        this.host.slots[o.slot].setVisible(false);
        this.host.slots[o.slot].pause();
        this.detach(o);
        o.cancelled = true;
      }
      this.screen = { type: 'still', pose };
      this.emit('clip', { clip: `still:${pose}`, kind: 'still', rate: 1 });
    };
    if (url) {
      this.host.still.load(url).then(
        () => reveal(true),
        () => reveal(false)
      );
    } else reveal(false);
  }

  private dropPending(): void {
    const p = this.pending;
    if (!p) return;
    this.pending = null;
    this.cancel(p);
    this.host.slots[p.slot].pause();
  }

  private cancel(s: Showing): void {
    s.cancelled = true;
    this.detach(s);
  }

  private detach(s: Showing): void {
    for (const off of s.off) off();
    s.off = [];
  }

  // ------------------------------------------------------------- preload and sound

  private preload(edge: string): void {
    const files = chooseFiles(this.edges.get(edge), this.host.formats, this.host.pixels());
    const attempt = (i: number): void => {
      if (this.destroyed || !this.engine) return;
      const file = files[i];
      if (!file) {
        if (!this.unplayable.has(edge)) {
          this.unplayable.add(edge);
          this.engine.markUnplayable(edge);
        }
        return;
      }
      this.cache.preload(file.key, file.url).then(
        (cached) => {
          if (cached && this.unplayable.delete(edge)) this.engine?.markPlayable(edge);
        },
        () => {
          this.failedKeys.add(file.key);
          attempt(i + 1);
        }
      );
    };
    attempt(0);
  }

  private playSound(edgeId: string): void {
    const s = this.edges.get(edgeId)?.sound;
    if (!s?.url) return;
    const loop = s.loop === true;
    const volume = Math.min(1, Math.max(0, s.volume ?? 1));
    const entry = { sound: this.host.sounds.play(s.url, volume, loop), loop };
    this.sounds.push(entry);
    if (!loop) entry.sound.onEnded(() => (this.sounds = this.sounds.filter((x) => x !== entry)));
    if (!this.running()) entry.sound.pause();
  }

  private stopSounds(onlyLooping: boolean): void {
    this.sounds = this.sounds.filter((s) => {
      if (onlyLooping && !s.loop) return true;
      s.sound.stop();
      return false;
    });
  }

  // ------------------------------------------------------------- delivery

  private useDelivery(delivery: Delivery): void {
    if (!delivery || typeof delivery !== 'object' || !delivery.runtimeGraph) {
      // The engine refuses it with its own code.
      this.delivery = delivery ?? null;
      return;
    }
    this.delivery = delivery;
    const index = indexDelivery(delivery);
    this.edges = index.edges;
    this.nodes = index.nodes;
  }

  /** Asks `getDelivery` for fresh links before the signed ones expire. */
  private scheduleRefresh(): void {
    if (this.refreshTimer !== null) this.host.clearTimer(this.refreshTimer);
    this.refreshTimer = null;
    if (this.destroyed || !this.options.getDelivery || !this.delivery) return;
    const at = expiresAt(this.delivery);
    if (at === null) return;
    const left = at - this.host.wallNow();
    const delay = left > 2 * REFRESH_LEAD_MS ? left - REFRESH_LEAD_MS : Math.max(left / 2, 0);
    this.refreshIn(delay);
  }

  private refreshIn(delay: number): void {
    if (this.refreshTimer !== null) this.host.clearTimer(this.refreshTimer);
    this.refreshTimer = this.host.setTimer(() => {
      this.refreshTimer = null;
      void this.refresh();
    }, Math.min(Math.max(0, delay), 2 ** 31 - 1));
  }

  private async refresh(): Promise<void> {
    const get = this.options.getDelivery;
    if (!get || this.destroyed || !this.delivery) return;
    const before = expiresAt(this.delivery);
    let input: DeliveryInput;
    try {
      input = await get();
    } catch (error) {
      if (this.destroyed) return;
      this.emit('error', { code: 'refresh_failed', detail: message(error) });
      this.refreshIn(REFRESH_RETRY_MS);
      return;
    }
    if (this.destroyed) return;
    if (!this.updateDelivery(input)) {
      this.refreshIn(REFRESH_RETRY_MS);
      return;
    }
    // Links that do not last longer are asked for again, not in a tight loop.
    const after = expiresAt(this.delivery);
    if (after !== null && before !== null && after <= before) this.refreshIn(REFRESH_RETRY_MS);
  }

  // ------------------------------------------------------------- events

  private emit<K extends MaskoEventName>(name: K, event: MaskoEvents[K]): void {
    const set = this.listeners.get(name);
    if (!set) return;
    for (const listener of [...set]) {
      try {
        (listener as MaskoListener<K>)(event);
      } catch (error) {
        // An app's handler must not stop the mascot; report it outside.
        this.later(() => {
          throw error;
        });
      }
    }
  }

  private later(fn: () => void): void {
    this.host.setTimer(fn, 0);
  }
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function isDomError(error: unknown): boolean {
  return typeof error === 'object' && error !== null && typeof (error as { name?: unknown }).name === 'string';
}
