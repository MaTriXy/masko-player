// The delivery as the native players take it: the delivery object's JSON.

import type { DeliveryInput } from './types';

/** The delivery object inside what the app gave, or the text as given when it is not JSON. */
function unwrap(input: DeliveryInput): unknown {
  let value: unknown = input;
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value);
    } catch {
      return input;
    }
  }
  for (const key of ['data', 'delivery']) {
    if (value && typeof value === 'object' && !('runtimeGraph' in value) && key in value) {
      value = (value as Record<string, unknown>)[key];
    }
  }
  return value;
}

/** The delivery's JSON for the native player. Text that is not JSON goes as is; the player refuses it. */
export function deliveryJson(input: DeliveryInput): string {
  const value = unwrap(input);
  return typeof value === 'string' ? value : JSON.stringify(value);
}

/** Which release a delivery is, links left out: a new release loads a new player, new links do not. */
export function releaseKey(input: DeliveryInput): string {
  const value = unwrap(input);
  if (!value || typeof value !== 'object') return String(value);
  const delivery = value as { release?: { id?: unknown }; runtimeGraph?: unknown };
  return JSON.stringify([delivery.release?.id ?? null, delivery.runtimeGraph ?? null], (_key, v: unknown) =>
    typeof v === 'string' && /^(https?:|blob:|data:|file:)/i.test(v) ? '' : v
  );
}
