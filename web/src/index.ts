// @masko/player: Masko mascots on the web, with no framework.

export { mountMascot, type MaskoHandle, type MountOptions } from './mount.ts';
export type { MaskoEventName, MaskoEvents, MaskoListener, Position } from './player.ts';
export type { Delivery, DeliveryInput } from './delivery.ts';
export { setWasmSource, type Value, type WasmSource } from './engine.ts';
