// mountMascot: the player in a page element, with the click and pointer
// wiring, the tap-to-play overlay and the click ripple (rules.md 14).

import { preferredFormats, type ClipFiles, type DeliveryInput } from './delivery.ts';
import { DomSlot, DomSounds, DomStill, FetchLoader, clipLength, onGesture } from './dom.ts';
import type { Value } from './engine.ts';
import type { Host } from './media.ts';
import { Player, type MaskoEventName, type MaskoListener, type PlayerOptions, type Position } from './player.ts';

/**
 * What the player plays: a release `delivery`, or one animation's `clip`
 * files (`webm` and `hevc`), looped on its own.
 */
export type MountOptions = MountCommon &
  ({ delivery: DeliveryInput; clip?: undefined } | { clip: ClipFiles; delivery?: undefined });

interface MountCommon {
  /** Returns a fresh delivery of the same release, before signed links expire. */
  getDelivery?: () => DeliveryInput | Promise<DeliveryInput>;
  /** Lets clips with their own voice be heard. On by default; false mutes them. Edge sounds play either way. */
  sound?: boolean;
  /** Starts at once. Defaults to the canvas's `autoPlay`, else true. */
  autoPlay?: boolean;
  /** Clicks and pointer enter/leave on the mascot reach the canvas. On by default. */
  pointer?: boolean;
}

/** What `mountMascot` returns: the same calls on every platform. */
export interface MaskoHandle {
  set(name: string, value: Value): void;
  fire(name: string): void;
  reset(): void;
  play(): void;
  pause(): void;
  destroy(): void;
  /** The clip on screen and its clip time in seconds. */
  position(): Position;
  /**
   * Swaps in fresh links of the release that is playing; the mascot keeps
   * playing. Another release is refused with `error` `refresh_mismatch`, a
   * delivery that cannot be read with `refresh_failed`. True when taken.
   */
  updateDelivery(delivery: DeliveryInput): boolean;
  /** Lets clips' own voices be heard, or not, from the next clip or loop on. */
  setSound(on: boolean): void;
  /** Listens to `pose`, `clip`, `reactionDone`, `movement` or `error`; returns the unsubscribe call. */
  on<K extends MaskoEventName>(event: K, handler: MaskoListener<K>): () => void;
  preview: { showPose(id: string): void; playMove(id: string): void };
}

const STYLE_ID = 'masko-player-style';
const CSS = `
.masko-player{position:relative;width:100%;height:100%;overflow:visible;-webkit-tap-highlight-color:transparent;user-select:none;-webkit-user-select:none}
.masko-player>video,.masko-player>img.masko-still{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;pointer-events:none;margin:0;padding:0;border:0;background:transparent;transition:none}
.masko-player>.masko-tap{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;margin:0;padding:0;border:0;background:transparent;cursor:pointer}
.masko-player>.masko-tap[hidden]{display:none}
.masko-player>.masko-tap>span{display:flex;align-items:center;justify-content:center;width:48px;height:48px;border-radius:50%;background:rgba(0,0,0,.55);box-shadow:0 2px 8px rgba(0,0,0,.25)}
.masko-player>.masko-ripple{position:absolute;width:12px;height:12px;margin:-6px 0 0 -6px;border-radius:50%;border:2px solid rgba(249,93,2,.8);pointer-events:none;animation:masko-ripple .5s ease-out forwards}
@keyframes masko-ripple{from{transform:scale(1);opacity:1}to{transform:scale(6);opacity:0}}
@media (prefers-reduced-motion:reduce){.masko-player>.masko-ripple{animation-duration:.01s}}
`;

function ensureStyle(doc: Document): void {
  if (doc.getElementById(STYLE_ID)) return;
  const style = doc.createElement('style');
  style.id = STYLE_ID;
  style.textContent = CSS;
  (doc.head ?? doc.documentElement).appendChild(style);
}

/**
 * Plays a mascot in `element`, which sets its size. Returns at once; the
 * engine loads in the background and calls made meanwhile are kept.
 */
export function mountMascot(element: HTMLElement, options: MountOptions): MaskoHandle {
  return handleFor(createPlayer(element, options).player);
}

/** The player and its DOM, for the React component. */
export function createPlayer(element: HTMLElement, options: MountOptions): { player: Player; root: HTMLElement } {
  const doc = element.ownerDocument;
  const win = doc.defaultView ?? window;
  ensureStyle(doc);

  const root = doc.createElement('div');
  root.className = 'masko-player';
  const videos = [doc.createElement('video'), doc.createElement('video')];
  videos.forEach((v, i) => {
    v.dataset.slot = String(i);
    root.appendChild(v);
  });
  const img = doc.createElement('img');
  img.className = 'masko-still';
  root.appendChild(img);
  const tap = doc.createElement('button');
  tap.type = 'button';
  tap.className = 'masko-tap';
  tap.hidden = true;
  tap.setAttribute('aria-label', 'Play');
  tap.innerHTML =
    '<span><svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true"><path d="M6 4l10 6-10 6z" fill="#fff"/></svg></span>';
  root.appendChild(tap);
  element.appendChild(root);
  const cleanups: (() => void)[] = [];

  // An element without a height: a square mascot as wide as it is. A hidden
  // element has no size at all yet: it is measured once it shows.
  const square = (): boolean => {
    const r = root.getBoundingClientRect();
    if (r.width === 0) return false;
    if (r.height === 0) {
      root.style.height = 'auto';
      root.style.aspectRatio = '1 / 1';
    }
    return true;
  };
  if (!square() && typeof win.ResizeObserver === 'function') {
    const observer = new win.ResizeObserver(() => {
      if (square()) observer.disconnect();
    });
    observer.observe(root);
    cleanups.push(() => observer.disconnect());
  }

  const slots: [DomSlot, DomSlot] = [new DomSlot(videos[0]), new DomSlot(videos[1])];
  const nav = win.navigator;
  const timers = new Set<number>();
  const host: Host = {
    now: () => win.performance.now(),
    wallNow: () => Date.now(),
    setTimer: (fn, ms) => {
      const id = win.setTimeout(() => {
        timers.delete(id);
        fn();
      }, ms);
      timers.add(id);
      return id;
    },
    clearTimer: (id) => {
      win.clearTimeout(id as number);
      timers.delete(id as number);
    },
    slots,
    still: new DomStill(img),
    sounds: new DomSounds(doc),
    files: new FetchLoader(),
    formats: preferredFormats(nav.userAgent, nav.maxTouchPoints ?? 0),
    pixels: () => {
      const r = root.getBoundingClientRect();
      return Math.max(r.width, r.height) * (win.devicePixelRatio || 1);
    },
    clipLength: (url) => clipLength(doc, url),
    onGesture: (fn) => onGesture(doc, fn),
    blocked: (on) => {
      tap.hidden = !on;
    },
    dispose: () => {
      for (const c of cleanups) c();
      for (const id of timers) win.clearTimeout(id);
      timers.clear();
      root.remove();
    }
  };

  const playerOptions: PlayerOptions = {
    delivery: options.delivery,
    clip: options.clip,
    getDelivery: options.getDelivery,
    sound: options.sound,
    autoPlay: options.autoPlay
  };
  const player = new Player(host, playerOptions);

  const ripple = player.clickEffect() === 'ripple';
  const listen = (target: EventTarget, type: string, fn: (e: Event) => void) => {
    target.addEventListener(type, fn);
    cleanups.push(() => target.removeEventListener(type, fn));
  };
  listen(tap, 'click', (e) => {
    e.stopPropagation();
    player.play();
  });
  if (options.pointer !== false) {
    /** The person clicks the mascot at (x, y) in it. */
    const poke = (x: number, y: number) => {
      player.click();
      if (!ripple) return;
      const dot = doc.createElement('span');
      dot.className = 'masko-ripple';
      dot.style.left = `${x}px`;
      dot.style.top = `${y}px`;
      dot.addEventListener('animationend', () => dot.remove());
      root.appendChild(dot);
    };
    listen(root, 'click', (e) => {
      if (!tap.hidden) return;
      const r = root.getBoundingClientRect();
      const m = e as MouseEvent;
      poke(m.clientX - r.left, m.clientY - r.top);
    });
    // Enter or Space while the mascot has focus is a click (rules.md 3.5).
    root.tabIndex = 0;
    root.setAttribute('role', 'button');
    root.setAttribute('aria-label', player.name() ?? 'Mascot');
    listen(root, 'keydown', (e) => {
      const k = e as KeyboardEvent;
      if (k.target !== root || (k.key !== 'Enter' && k.key !== ' ') || k.repeat || k.altKey || k.ctrlKey || k.metaKey) return;
      k.preventDefault();
      if (!tap.hidden) {
        player.play();
        return;
      }
      const r = root.getBoundingClientRect();
      poke(r.width / 2, r.height / 2);
    });
    listen(root, 'pointerenter', () => player.hover(true));
    listen(root, 'pointerleave', () => player.hover(false));
  }
  listen(doc, 'visibilitychange', () => player.setHidden(doc.visibilityState === 'hidden'));
  // Timers may have slept with the device: check the signed links again.
  listen(win, 'online', () => player.checkLinks());
  if (doc.visibilityState === 'hidden') player.setHidden(true);
  return { player, root };
}

/** The app's handle on a player. */
export function handleFor(player: Player): MaskoHandle {
  return {
    set: (name, value) => player.set(name, value),
    fire: (name) => player.fire(name),
    reset: () => player.reset(),
    play: () => player.play(),
    pause: () => player.pause(),
    destroy: () => player.destroy(),
    position: () => player.position(),
    updateDelivery: (delivery) => player.updateDelivery(delivery),
    setSound: (on) => player.setSound(on),
    on: (event, handler) => player.on(event, handler),
    preview: player.preview
  };
}
