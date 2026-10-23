/**
 * Play time in whole milliseconds: 0 when the mascot starts, moving with real
 * time, stopped while paused (rules.md 11.2). `source` is a monotonic clock in
 * milliseconds, `performance.now` in a browser.
 */
export class PlayClock {
  private readonly source: () => number;
  private base = 0;
  private since: number | null = null;

  constructor(source: () => number) {
    this.source = source;
  }

  get running(): boolean {
    return this.since !== null;
  }

  now(): number {
    const moving = this.since === null ? 0 : this.source() - this.since;
    return Math.max(0, Math.floor(this.base + moving));
  }

  play(): void {
    if (this.since === null) this.since = this.source();
  }

  pause(): void {
    if (this.since === null) return;
    this.base += this.source() - this.since;
    this.since = null;
  }
}
