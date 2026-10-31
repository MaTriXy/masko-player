// What the app gives and hears: the same names as the other players
// (spec/player.md, "What the app sees").

import 'package:flutter/foundation.dart';

/// What a clip on screen is: a pose's clip, a move, or a pose's still.
enum MaskoClipKind { pose, move, still }

/// A clip, or a pose's still (`still:<pose>`), is now on screen.
@immutable
class MaskoClipEvent {
  const MaskoClipEvent({required this.clip, required this.kind, required this.rate});

  /// The edge on screen, or `still:<pose>`.
  final String clip;
  final MaskoClipKind kind;

  /// The playback rate.
  final double rate;

  @override
  String toString() => 'MaskoClipEvent($clip, ${kind.name}, x$rate)';
}

/// A fire is done: used by a start, or spent unused.
@immutable
class MaskoReactionDoneEvent {
  const MaskoReactionDoneEvent({required this.name, required this.used});

  /// The full name, as `action::boop`.
  final String name;
  final bool used;

  @override
  String toString() => 'MaskoReactionDoneEvent($name, ${used ? 'used' : 'unused'})';
}

/// A move with `movement` is now on screen: the app may move the mascot as
/// the edge's `movement` says, over [seconds]. The player never moves itself.
@immutable
class MaskoMovementEvent {
  const MaskoMovementEvent({
    required this.edge,
    required this.movement,
    required this.rate,
    required this.seconds,
  });

  final String edge;

  /// The edge's `movement`, as decoded JSON.
  final Object? movement;
  final double rate;

  /// The edge's duration at this rate.
  final double seconds;

  @override
  String toString() => 'MaskoMovementEvent($edge, $movement, x$rate, ${seconds}s)';
}

/// Something went wrong, with a code from the rulebook or the player.
@immutable
class MaskoErrorEvent {
  const MaskoErrorEvent({required this.code, this.detail});

  final String code;

  /// What it is about: the clip of a clip error, the name of a refused
  /// value, the pose of a pose error.
  final String? detail;

  @override
  String toString() => 'MaskoErrorEvent($code${detail == null ? '' : ', $detail'})';
}

/// The clip on screen and its clip time, in seconds of its file.
@immutable
class MaskoPosition {
  const MaskoPosition({required this.clip, required this.time});

  /// The edge on screen, `still:<pose>`, or null before anything shows.
  final String? clip;

  /// Clip time in seconds; 0 for a still or nothing.
  final double time;

  static const nothing = MaskoPosition(clip: null, time: 0);

  @override
  String toString() => 'MaskoPosition($clip, ${time}s)';
}

/// One animation's files, played on its own: HEVC on iOS, the stacked MP4
/// on Android.
@immutable
class MaskoClipFiles {
  const MaskoClipFiles({this.hevc, this.stacked});

  final String? hevc;
  final String? stacked;
}
