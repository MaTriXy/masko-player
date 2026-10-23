// The release delivery as the player reads it for media: files, sounds,
// stills and movement. The engine reads the rules from the same JSON.

export type Format = 'webm' | 'hevc';

export interface Files {
  webm?: string;
  hevc?: string;
  stacked?: string;
}

export interface DeliveryEdge {
  id: string;
  source: string;
  target: string;
  isLoop: boolean;
  duration: number;
  videos?: Files & { variants?: Record<string, Files> };
  sound?: { url?: string; volume?: number; loop?: boolean };
  hasAudio?: boolean;
  movement?: unknown;
  [key: string]: unknown;
}

export interface DeliveryNode {
  id: string;
  name?: string;
  transparentThumbnailUrl?: string;
  [key: string]: unknown;
}

export interface Delivery {
  deliverySchemaVersion: number;
  playerContract?: number;
  requires?: string[];
  release?: { id?: string; [key: string]: unknown };
  deliveryAccess?: { urlMode?: 'signed' | 'public'; signedUrlExpiresAt?: string; lastFetchedAt?: string };
  runtimeGraph: {
    initialNode: string;
    autoPlay?: boolean;
    clickEffect?: 'ripple' | 'none';
    nodes: DeliveryNode[];
    edges: DeliveryEdge[];
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

/**
 * What `delivery` accepts: the delivery, its JSON, or the API response around
 * it (`{ data: { delivery } }` from `GET .../releases/{id}/delivery`).
 */
export type DeliveryInput = Delivery | string | { delivery: Delivery } | { data: { delivery: Delivery } };

/** The delivery object, and its JSON for the engine. Throws on text that is not JSON. */
export function readDelivery(input: DeliveryInput): { delivery: Delivery; json: string } {
  let value: unknown = typeof input === 'string' ? JSON.parse(input) : input;
  for (const key of ['data', 'delivery']) {
    if (value && typeof value === 'object' && !('runtimeGraph' in value) && key in value) {
      value = (value as Record<string, unknown>)[key];
    }
  }
  return { delivery: value as Delivery, json: JSON.stringify(value) };
}

/** One file to try: a cache key that survives signed-link refreshes, and its URL. */
export interface FileChoice {
  key: string;
  url: string;
}

/**
 * The files to try for an edge, best first: the preferred format, then the
 * other one (spec/player.md, "The file and the size"). With size variants,
 * the smallest at least `pixels` large, else the base file, else the largest.
 */
export function chooseFiles(edge: DeliveryEdge | undefined, formats: Format[], pixels: number): FileChoice[] {
  const videos = edge?.videos;
  if (!edge || !videos) return [];
  const sizes = Object.entries(videos.variants ?? {})
    .map(([size, files]) => ({ size: Number(size), files }))
    .filter((v) => Number.isFinite(v.size) && v.size > 0)
    .sort((a, b) => a.size - b.size);
  const out: FileChoice[] = [];
  for (const format of formats) {
    // An unknown size (not laid out yet) takes the base file.
    const fit = pixels > 0 ? sizes.find((v) => v.size >= pixels && v.files[format]) : undefined;
    let pick: FileChoice | undefined;
    if (fit) pick = { key: `${edge.id}|${format}|${fit.size}`, url: fit.files[format]! };
    else if (videos[format]) pick = { key: `${edge.id}|${format}`, url: videos[format]! };
    else {
      const largest = [...sizes].reverse().find((v) => v.files[format]);
      if (largest) pick = { key: `${edge.id}|${format}|${largest.size}`, url: largest.files[format]! };
    }
    if (pick) out.push(pick);
  }
  return out;
}

/** HEVC on Safari and on every iPhone and iPad browser, WebM elsewhere. */
export function preferredFormats(userAgent: string, maxTouchPoints = 0): Format[] {
  const apple = /iPad|iPhone|iPod/.test(userAgent) || (/Macintosh/.test(userAgent) && maxTouchPoints > 1);
  const safari = /Safari\//.test(userAgent) && !/(Chrome|Chromium|CriOS|FxiOS|EdgiOS|Edg|OPR|Android|Firefox)\//.test(userAgent);
  return apple || safari ? ['hevc', 'webm'] : ['webm', 'hevc'];
}

/** When the signed links expire, in wall-clock milliseconds, if they do. */
export function expiresAt(delivery: Delivery): number | null {
  const access = delivery.deliveryAccess;
  if (!access?.signedUrlExpiresAt) return null;
  const t = Date.parse(access.signedUrlExpiresAt);
  return Number.isFinite(t) ? t : null;
}

/** The release with its links left out: two deliveries with the same shape differ only in URLs. */
export function releaseShape(delivery: Delivery): string {
  return JSON.stringify([delivery.release?.id ?? null, delivery.runtimeGraph], (_key, value: unknown) =>
    typeof value === 'string' && /^(https?:|blob:|data:)/i.test(value) ? '' : value
  );
}

/** Whether `fresh` is the same release as `current`, so only its URLs may change. */
export function sameRelease(current: Delivery, fresh: Delivery): boolean {
  if (!fresh || typeof fresh !== 'object' || !fresh.runtimeGraph) return false;
  return releaseShape(current) === releaseShape(fresh);
}

export function indexDelivery(delivery: Delivery): {
  edges: Map<string, DeliveryEdge>;
  nodes: Map<string, DeliveryNode>;
} {
  return {
    edges: new Map(delivery.runtimeGraph.edges.map((e) => [e.id, e])),
    nodes: new Map(delivery.runtimeGraph.nodes.map((n) => [n.id, n]))
  };
}
