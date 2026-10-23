import type { FileLoader } from './media.ts';

interface Entry {
  key: string;
  load: Promise<string>;
  src: string | null;
  batch: number;
  users: number;
  abort: AbortController;
}

/**
 * The preload cache: a few whole clip files, so a later `showClip` swaps
 * without waiting (spec/player.md, `preload`). Keys name a file (edge,
 * format, size), not its URL, so cached files survive a signed-link refresh.
 * Each pose's preloads come most important first; when the cache is full,
 * older poses' files go first and a pose's later preloads are skipped.
 */
export class ClipCache {
  private readonly files: FileLoader;
  private readonly capacity: number;
  private readonly entries = new Map<string, Entry>();
  private batch = 0;

  constructor(files: FileLoader, capacity = 6) {
    this.files = files;
    this.capacity = capacity;
  }

  /** A pose was entered: the preloads that follow are the ones to keep. */
  nextBatch(): void {
    this.batch++;
  }

  /** Loads a file. Resolves true when cached, false when skipped; rejects when it cannot load. */
  preload(key: string, url: string): Promise<boolean> {
    const known = this.entries.get(key);
    if (known) {
      known.batch = this.batch;
      this.entries.delete(key);
      this.entries.set(key, known);
      return known.load.then(() => true);
    }
    if (!this.makeRoom()) return Promise.resolve(false);
    const abort = new AbortController();
    const entry: Entry = { key, src: null, batch: this.batch, users: 0, abort, load: Promise.resolve('') };
    entry.load = this.files.load(url, abort.signal).then(
      (src) => {
        if (this.entries.get(key) === entry) entry.src = src;
        else this.files.free(src);
        return src;
      },
      (error: unknown) => {
        if (this.entries.get(key) === entry) this.entries.delete(key);
        throw error;
      }
    );
    this.entries.set(key, entry);
    return entry.load.then(
      () => true,
      (error: unknown) => {
        // Dropped to make room or by `clear`: not a file that fails.
        if (abort.signal.aborted) return false;
        throw error;
      }
    );
  }

  /** The cached or loading file for a slot to play, kept until `release`. */
  acquire(key: string): Promise<string> | null {
    const entry = this.entries.get(key);
    if (!entry) return null;
    entry.users++;
    return entry.load;
  }

  release(key: string): void {
    const entry = this.entries.get(key);
    if (entry && entry.users > 0) entry.users--;
  }

  has(key: string): boolean {
    return this.entries.has(key);
  }

  get size(): number {
    return this.entries.size;
  }

  /** Frees every file, including those in use: the player is going away. */
  clear(): void {
    for (const entry of [...this.entries.values()]) this.drop(entry);
  }

  private makeRoom(): boolean {
    if (this.entries.size < this.capacity) return true;
    for (const entry of this.entries.values()) {
      if (entry.batch !== this.batch && entry.users === 0) {
        this.drop(entry);
        return true;
      }
    }
    return false;
  }

  private drop(entry: Entry): void {
    this.entries.delete(entry.key);
    entry.abort.abort();
    if (entry.src) this.files.free(entry.src);
  }
}
