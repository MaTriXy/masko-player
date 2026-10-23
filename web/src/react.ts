// <MaskoPlayer>: the player as a React component, using the app's React.
// The handle comes through a ref, the events as props.

import {
  createElement,
  forwardRef,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  type CSSProperties,
  type ForwardedRef
} from 'react';
import { readDelivery, releaseShape, type DeliveryInput } from './delivery.ts';
import { createPlayer, handleFor, type MaskoHandle, type MountOptions } from './mount.ts';
import type { MaskoEventName, MaskoEvents, Player } from './player.ts';

export type { MaskoHandle, MountOptions } from './mount.ts';
export type { MaskoEvents, Position } from './player.ts';

export interface MaskoPlayerProps extends MountOptions {
  className?: string;
  style?: CSSProperties;
  onPose?: (event: MaskoEvents['pose']) => void;
  onClip?: (event: MaskoEvents['clip']) => void;
  onReactionDone?: (event: MaskoEvents['reactionDone']) => void;
  onMovement?: (event: MaskoEvents['movement']) => void;
  onError?: (event: MaskoEvents['error']) => void;
}

const EVENTS: [MaskoEventName, keyof MaskoPlayerProps][] = [
  ['pose', 'onPose'],
  ['clip', 'onClip'],
  ['reactionDone', 'onReactionDone'],
  ['movement', 'onMovement'],
  ['error', 'onError']
];

/** Which release a delivery is: a new release mounts a new player, new links only swap URLs. */
function releaseKey(delivery: DeliveryInput): string {
  try {
    return releaseShape(readDelivery(delivery).delivery);
  } catch {
    return String(delivery);
  }
}

function MaskoPlayerView(props: MaskoPlayerProps, ref: ForwardedRef<MaskoHandle>) {
  const box = useRef<HTMLDivElement>(null);
  const player = useRef<Player | null>(null);
  const latest = useRef(props);
  latest.current = props;
  const mounted = useRef<DeliveryInput | null>(null);
  const key = useMemo(() => releaseKey(props.delivery), [props.delivery]);
  const hasRefresh = props.getDelivery !== undefined;

  useEffect(() => {
    const element = box.current;
    if (!element) return;
    const p = latest.current;
    const created = createPlayer(element, {
      delivery: p.delivery,
      getDelivery: hasRefresh ? () => latest.current.getDelivery!() : undefined,
      sound: p.sound,
      autoPlay: p.autoPlay,
      pointer: p.pointer
    }).player;
    for (const [event, prop] of EVENTS) {
      created.on(event, (e) => {
        const handler = latest.current[prop] as ((e: unknown) => void) | undefined;
        handler?.(e);
      });
    }
    player.current = created;
    mounted.current = p.delivery;
    return () => {
      created.destroy();
      player.current = null;
    };
    // A new player only for a new release or new pointer wiring.
  }, [key, props.pointer, hasRefresh]);

  // New links for the same release: swap URLs, keep playing.
  useEffect(() => {
    if (!player.current || mounted.current === props.delivery) return;
    mounted.current = props.delivery;
    player.current.updateDelivery(props.delivery);
  }, [props.delivery]);

  useEffect(() => {
    player.current?.setSound(props.sound ?? false);
  }, [props.sound]);

  useImperativeHandle(
    ref,
    (): MaskoHandle => ({
      set: (name, value) => player.current?.set(name, value),
      fire: (name) => player.current?.fire(name),
      reset: () => player.current?.reset(),
      play: () => player.current?.play(),
      pause: () => player.current?.pause(),
      destroy: () => player.current?.destroy(),
      position: () => player.current?.position() ?? { clip: null, time: 0 },
      on: (event, handler) => (player.current ? handleFor(player.current).on(event, handler) : () => undefined),
      preview: {
        showPose: (id) => player.current?.preview.showPose(id),
        playMove: (id) => player.current?.preview.playMove(id)
      }
    }),
    []
  );

  return createElement('div', { ref: box, className: props.className, style: props.style });
}

/** A Masko mascot. Size it with `className` or `style`; drive it through the ref. */
export const MaskoPlayer = forwardRef<MaskoHandle, MaskoPlayerProps>(MaskoPlayerView);
MaskoPlayer.displayName = 'MaskoPlayer';
