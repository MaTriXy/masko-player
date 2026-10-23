// The browser side of media.ts: video slots, the still, sounds and the file
// loader for the preload cache.

import type { FileLoader, Sound, SoundOut, StillLayer, VideoSlot } from './media.ts';

const HAVE_CURRENT_DATA = 2;

type FrameVideo = HTMLVideoElement & {
  requestVideoFrameCallback?: (cb: () => void) => number;
  cancelVideoFrameCallback?: (id: number) => void;
};

/** A persistent `<video>`: muted, inline, hidden until swapped in. */
export class DomSlot implements VideoSlot {
  readonly el: FrameVideo;
  src: string | null = null;

  constructor(el: HTMLVideoElement) {
    this.el = el;
    el.muted = true;
    el.defaultMuted = true;
    el.playsInline = true;
    el.preload = 'auto';
    el.loop = false;
    el.setAttribute('muted', '');
    el.setAttribute('playsinline', '');
    el.setAttribute('disablepictureinpicture', '');
    el.setAttribute('disableremoteplayback', '');
    el.setAttribute('aria-hidden', 'true');
    this.setVisible(false);
  }

  get time(): number {
    return this.el.currentTime || 0;
  }

  load(src: string): void {
    if (this.src === src) {
      this.el.currentTime = 0;
      return;
    }
    this.src = src;
    this.el.src = src;
  }

  play(rate: number, muted: boolean): Promise<void> {
    this.el.defaultPlaybackRate = rate;
    this.el.playbackRate = rate;
    this.el.muted = muted;
    try {
      return this.el.play() ?? Promise.resolve();
    } catch (error) {
      return Promise.reject(error);
    }
  }

  pause(): void {
    this.el.pause();
  }

  setVisible(on: boolean): void {
    this.el.style.opacity = on ? '1' : '0';
    this.el.dataset.visible = on ? 'true' : 'false';
  }

  onFrame(fn: () => void): () => void {
    const el = this.el;
    const frames = typeof el.requestVideoFrameCallback === 'function';
    let done = false;
    let raf = 0;
    let id = 0;
    const off = () => {
      if (frames) el.cancelVideoFrameCallback?.(id);
      for (const e of events) el.removeEventListener(e, check);
      if (raf) cancelAnimationFrame(raf);
    };
    const fire = () => {
      if (done) return;
      done = true;
      off();
      fn();
    };
    // Without frame callbacks (older Firefox), a frame is decoded once the
    // element plays with current data. With them, the same test once the
    // play position has moved is a backstop for a browser that skips the
    // callback on a hidden video. Either way the swap waits for the next
    // animation frame.
    const check = () => {
      if (raf || el.paused || el.readyState < HAVE_CURRENT_DATA) return;
      if (frames && !(el.currentTime > 0)) return;
      raf = requestAnimationFrame(fire);
    };
    const events = frames ? ['timeupdate'] : ['playing', 'timeupdate', 'loadeddata'];
    for (const e of events) el.addEventListener(e, check);
    if (frames) {
      // Runs in the rendering step that presents the frame: the swap lands
      // in that same frame.
      id = el.requestVideoFrameCallback!(fire);
    } else {
      check();
    }
    return () => {
      done = true;
      off();
    };
  }

  onReady(fn: () => void): () => void {
    const el = this.el;
    let done = false;
    const fire = () => {
      if (done) return;
      done = true;
      el.removeEventListener('loadeddata', fire);
      fn();
    };
    if (el.readyState >= HAVE_CURRENT_DATA) queueMicrotask(fire);
    else el.addEventListener('loadeddata', fire);
    return () => {
      done = true;
      el.removeEventListener('loadeddata', fire);
    };
  }

  onEnded(fn: () => void): () => void {
    this.el.addEventListener('ended', fn);
    return () => this.el.removeEventListener('ended', fn);
  }

  onError(fn: () => void): () => void {
    this.el.addEventListener('error', fn);
    return () => this.el.removeEventListener('error', fn);
  }

  unload(): void {
    this.src = null;
    this.el.removeAttribute('src');
    this.el.load();
  }
}

/** The pose's still image, decoded before it shows. */
export class DomStill implements StillLayer {
  readonly el: HTMLImageElement;

  constructor(el: HTMLImageElement) {
    this.el = el;
    el.alt = '';
    el.decoding = 'async';
    el.draggable = false;
    this.setVisible(false);
  }

  async load(url: string): Promise<void> {
    const img = new Image();
    img.decoding = 'async';
    img.src = url;
    await img.decode();
    this.el.src = url;
    // The visible element decodes from the image cache.
    await this.el.decode().catch(() => undefined);
  }

  setVisible(on: boolean): void {
    this.el.style.opacity = on ? '1' : '0';
    this.el.dataset.visible = on ? 'true' : 'false';
  }
}

/** Edge sounds through `<audio>` elements. Blocked autoplay keeps them silent. */
export class DomSounds implements SoundOut {
  play(url: string, volume: number, loop: boolean): Sound {
    const audio = new Audio(url);
    audio.volume = volume;
    audio.loop = loop;
    let stopped = false;
    let ended: (() => void) | null = null;
    audio.addEventListener('ended', () => ended?.());
    const start = () => audio.play().catch(() => undefined);
    void start();
    return {
      stop: () => {
        stopped = true;
        audio.pause();
        audio.removeAttribute('src');
        audio.load();
      },
      pause: () => audio.pause(),
      resume: () => {
        if (!stopped && !audio.ended) void start();
      },
      onEnded: (fn) => {
        ended = fn;
      }
    };
  }
}

/**
 * Loads whole clip files into memory and plays them from object URLs. When
 * a host does not allow `fetch` from this page (no CORS), it checks that the
 * file loads in a detached `<video>` and lets the browser cache it instead.
 */
export class FetchLoader implements FileLoader {
  async load(url: string, signal: AbortSignal): Promise<string> {
    let response: Response;
    try {
      response = await fetch(url, { signal, credentials: 'omit' });
    } catch (error) {
      if (signal.aborted) throw error;
      await probe(url, signal);
      return url;
    }
    if (!response.ok) throw new Error(`${response.status} ${url}`);
    const blob = await response.blob();
    return URL.createObjectURL(blob);
  }

  free(src: string): void {
    if (src.startsWith('blob:')) URL.revokeObjectURL(src);
  }
}

function probe(url: string, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const v = document.createElement('video');
    v.muted = true;
    v.preload = 'auto';
    const done = (ok: boolean) => {
      v.removeAttribute('src');
      v.load();
      if (ok) resolve();
      else reject(new Error(`cannot load ${url}`));
    };
    v.addEventListener('loadeddata', () => done(true), { once: true });
    v.addEventListener('error', () => done(false), { once: true });
    signal.addEventListener('abort', () => done(false), { once: true });
    v.src = url;
  });
}
