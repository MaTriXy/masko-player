// masko_player on a device: the Swift player on an iOS simulator or iPhone,
// the Kotlin player on an Android emulator or phone, playing the example
// release from the clip server (../react-native/server/serve.mjs).
//
//   node ../react-native/server/serve.mjs
//   flutter test integration_test -d <device>

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masko_player/masko_player.dart';
import 'package:masko_player_example/main.dart' show fetchDelivery, server;

/// Everything a view reported, in order.
class Heard {
  final poses = <String>[];
  final clips = <MaskoClipEvent>[];
  final reactions = <MaskoReactionDoneEvent>[];
  final movements = <MaskoMovementEvent>[];
  final errors = <MaskoErrorEvent>[];
  final lines = <String>[];

  int get count => lines.length;

  bool sawClip(String clip) => clips.any((c) => c.clip == clip);

  @override
  String toString() => lines.join('\n');
}

/// The example release's delivery object, a copy the test may change.
Future<Map<String, Object?>> release() async {
  final api = await fetchDelivery();
  final delivery = (api['data']! as Map)['delivery'];
  return (jsonDecode(jsonEncode(delivery)) as Map).cast<String, Object?>();
}

/// Saves [url] to [to] on the device.
Future<void> download(Uri url, File to) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(url)).close();
    if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}', uri: url);
    await response.pipe(to.openWrite());
  } finally {
    client.close();
  }
}

/// The example release with every clip saved on the device and its links
/// pointing at the files, as an app that bundles or self-hosts its mascot.
Future<Map<String, Object?>> releaseOnDevice() async {
  final delivery = await release();
  final folder = await Directory.systemTemp.createTemp('masko-files');
  for (final edge in (delivery['runtimeGraph']! as Map)['edges']! as List) {
    final videos = (edge as Map)['videos'] as Map? ?? {};
    for (final format in videos.keys.toList()) {
      final url = Uri.parse(videos[format]! as String);
      final file = File('${folder.path}/${url.pathSegments.last}');
      if (!file.existsSync()) await download(url, file);
      videos[format] = file.uri.toString();
    }
  }
  delivery['deliveryAccess'] = {'urlMode': 'public', 'lastFetchedAt': DateTime.now().toUtc().toIso8601String()};
  return delivery;
}

Widget mascot(
  Heard heard, {
  Object? delivery,
  MaskoClipFiles? clip,
  MaskoController? controller,
  Future<Object?> Function()? getDelivery,
  bool? autoPlay,
  VoidCallback? onTap,
}) {
  void note(String line) => heard.lines.add(line);
  final view = MaskoView(
    delivery: delivery,
    clip: clip,
    controller: controller,
    getDelivery: getDelivery,
    autoPlay: autoPlay,
    sound: false,
    onPose: (pose) {
      heard.poses.add(pose);
      note('pose $pose');
    },
    onClip: (e) {
      heard.clips.add(e);
      note('clip ${e.clip} ${e.kind.name}');
    },
    onReactionDone: (e) {
      heard.reactions.add(e);
      note('reactionDone ${e.name} ${e.used}');
    },
    onMovement: (e) {
      heard.movements.add(e);
      note('movement ${e.edge} ${e.movement}');
    },
    onError: (e) {
      heard.errors.add(e);
      note('error ${e.code} ${e.detail}');
    },
  );
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox(
        width: 200,
        height: 200,
        child: onTap == null ? view : GestureDetector(onTap: onTap, child: view),
      ),
    ),
  );
}

/// Waits, in real time, until [done] holds.
Future<void> until(
  WidgetTester tester,
  bool Function() done,
  String what,
  Heard heard, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for $what. Heard:\n$heard');
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Lets [time] pass in real time, with frames.
Future<void> wait(WidgetTester tester, Duration time) async {
  final end = DateTime.now().add(time);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('plays a release from the API response, from its first pose', (tester) async {
    final heard = Heard();
    await tester.pumpWidget(mascot(heard, delivery: await fetchDelivery()));
    await until(tester, () => heard.sawClip('idle'), 'the idle loop', heard);
    expect(heard.poses.first, 'idle');
    expect(heard.clips.firstWhere((c) => c.clip == 'idle').kind, MaskoClipKind.pose);
    expect(heard.errors, isEmpty, reason: '$heard');
  });

  testWidgets('set starts the move its value decides, then the next pose', (tester) async {
    final heard = Heard();
    final controller = MaskoController();
    await tester.pumpWidget(mascot(heard, delivery: await release(), controller: controller));
    await until(tester, () => heard.sawClip('idle'), 'the idle loop', heard);
    controller.set('working', true);
    await until(tester, () => heard.sawClip('work'), 'the work loop', heard);
    expect(heard.poses, ['idle', 'working']);
    expect(heard.clips.map((c) => c.clip), containsAllInOrder(['idle', 'to-work', 'work']));
    expect(heard.clips.firstWhere((c) => c.clip == 'to-work').kind, MaskoClipKind.move);
    final move = heard.movements.single;
    expect(move.edge, 'to-work');
    expect((move.movement! as Map)['dy'], -24);
    expect(move.seconds, closeTo(0.5, 0.01));
    expect(heard.errors, isEmpty, reason: '$heard');
  });

  testWidgets('a fire the pose wants is used', (tester) async {
    final heard = Heard();
    final controller = MaskoController();
    await tester.pumpWidget(mascot(heard, delivery: await release(), controller: controller));
    await until(tester, () => heard.sawClip('idle'), 'the idle loop', heard);
    controller.fire('celebrate');
    await until(tester, () => heard.reactions.isNotEmpty, 'reactionDone', heard);
    expect(heard.sawClip('celebrate'), isTrue, reason: '$heard');
    expect(heard.reactions.single.name, 'behavior::celebrate');
    expect(heard.reactions.single.used, isTrue);
  });

  testWidgets('a fire nothing wants is dropped', (tester) async {
    final heard = Heard();
    final controller = MaskoController();
    await tester.pumpWidget(mascot(heard, delivery: await release(), controller: controller));
    controller.set('working', true);
    await until(tester, () => heard.sawClip('work'), 'the work loop', heard);
    controller.fire('celebrate');
    await until(tester, () => heard.reactions.isNotEmpty, 'reactionDone', heard);
    expect(heard.reactions.single.used, isFalse);
    expect(heard.sawClip('celebrate'), isFalse);
  });

  testWidgets('values set before the view starts choose the first pose', (tester) async {
    final delivery = await release();
    // An Any State edge into working: what holds at start enters its pose directly.
    final graph = delivery['runtimeGraph']! as Map;
    (graph['edges']! as List).add({
      'id': 'any-work',
      'source': '*',
      'target': 'working',
      'isLoop': false,
      'duration': 0,
      'videos': <String, Object?>{},
      'conditions': [
        {'input': 'behavior::working', 'op': '==', 'value': true},
      ],
    });
    delivery['requires'] = ['any-state'];
    final heard = Heard();
    final controller = MaskoController()..set('working', true);
    await tester.pumpWidget(mascot(heard, delivery: delivery, controller: controller));
    await until(tester, () => heard.sawClip('work'), 'the work loop', heard);
    expect(heard.poses.first, 'working', reason: '$heard');
    expect(heard.movements, isEmpty);
    expect(heard.errors, isEmpty, reason: '$heard');
  });

  testWidgets('position names the clip on screen and its time', (tester) async {
    final heard = Heard();
    final controller = MaskoController();
    expect((await controller.position()).clip, isNull);
    await tester.pumpWidget(mascot(heard, delivery: await release(), controller: controller));
    await until(tester, () => heard.sawClip('idle'), 'the idle loop', heard);
    await wait(tester, const Duration(milliseconds: 300));
    final at = await controller.position();
    expect(at.clip, 'idle');
    expect(at.time, inInclusiveRange(0, 1.05));
  });

  testWidgets('pause holds the clip time and play resumes it', (tester) async {
    final heard = Heard();
    final controller = MaskoController();
    await tester.pumpWidget(mascot(heard, delivery: await release(), controller: controller));
    await until(tester, () => heard.sawClip('idle'), 'the idle loop', heard);
    controller.pause();
    await wait(tester, const Duration(milliseconds: 400));
    final paused = await controller.position();
    await wait(tester, const Duration(milliseconds: 700));
    final still = await controller.position();
    expect(still.clip, paused.clip);
    expect(still.time, closeTo(paused.time, 0.02));
    controller.play();
    await wait(tester, const Duration(milliseconds: 500));
    final moved = await controller.position();
    expect(moved.clip != still.clip || (moved.time - still.time).abs() > 0.1, isTrue,
        reason: 'paused at $still, after play $moved');
  });

  testWidgets('autoPlay false waits on the first frame for play', (tester) async {
    final heard = Heard();
    final controller = MaskoController();
    await tester.pumpWidget(mascot(heard, delivery: await release(), controller: controller, autoPlay: false));
    await wait(tester, const Duration(milliseconds: 1500));
    final waiting = await controller.position();
    expect(waiting.time, lessThan(0.05), reason: '$waiting\n$heard');
    controller.play();
    await until(tester, () => heard.sawClip('idle'), 'the idle loop', heard);
    var at = MaskoPosition.nothing;
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (at.time <= 0.1 && DateTime.now().isBefore(end)) {
      await wait(tester, const Duration(milliseconds: 100));
      at = await controller.position();
    }
    expect(at.time, greaterThan(0.1), reason: 'the clip time after play: $at\n$heard');
  });

  testWidgets('reset brings the defaults back and starts again', (tester) async {
    final heard = Heard();
    final controller = MaskoController();
    await tester.pumpWidget(mascot(heard, delivery: await release(), controller: controller));
    controller.set('working', true);
    await until(tester, () => heard.poses.contains('working'), 'the working pose', heard);
    controller.reset();
    await until(tester, () => heard.poses.last == 'idle', 'idle again', heard);
    expect(heard.poses, ['idle', 'working', 'idle']);
  });

  testWidgets('preview calls cut to a pose and play a move', (tester) async {
    final heard = Heard();
    final controller = MaskoController();
    await tester.pumpWidget(mascot(heard, delivery: await release(), controller: controller));
    await until(tester, () => heard.sawClip('idle'), 'the idle loop', heard);
    controller.preview.showPose('working');
    await until(tester, () => heard.poses.contains('working'), 'the working pose', heard);
    expect(heard.movements, isEmpty);
    controller.preview.playMove('to-idle');
    await until(tester, () => heard.movements.isNotEmpty, 'the to-idle move', heard);
    expect(heard.movements.single.edge, 'to-idle');
  });

  testWidgets('new links for the same release keep the player; a new release restarts it', (tester) async {
    final heard = Heard();
    final controller = MaskoController();
    await tester.pumpWidget(mascot(heard, delivery: await release(), controller: controller));
    controller.set('working', true);
    await until(tester, () => heard.sawClip('work'), 'the work loop', heard);

    // The server signs every delivery anew: same release, new links.
    await tester.pumpWidget(mascot(heard, delivery: await release(), controller: controller));
    await wait(tester, const Duration(milliseconds: 1500));
    expect(heard.poses, ['idle', 'working'], reason: '$heard');
    expect(heard.errors, isEmpty, reason: '$heard');

    final next = await release();
    next['release'] = {'id': 'example-release-2'};
    await tester.pumpWidget(mascot(heard, delivery: next, controller: controller));
    await until(tester, () => heard.poses.length == 3, 'the new release', heard);
    expect(heard.poses.last, 'idle');
  });

  testWidgets('getDelivery runs before the links expire', (tester) async {
    final delivery = await release();
    final now = DateTime.now().toUtc();
    delivery['deliveryAccess'] = {
      'urlMode': 'signed',
      'signedUrlExpiresAt': now.add(const Duration(seconds: 20)).toIso8601String(),
      'lastFetchedAt': now.toIso8601String(),
    };
    final heard = Heard();
    var asked = 0;
    await tester.pumpWidget(mascot(heard, delivery: delivery, getDelivery: () {
      asked += 1;
      return fetchDelivery();
    }));
    await until(tester, () => asked > 0, 'getDelivery', heard, timeout: const Duration(seconds: 25));
    await wait(tester, const Duration(seconds: 1));
    expect(heard.errors, isEmpty, reason: '$heard');
    expect(heard.poses, ['idle'], reason: 'fresh links keep the player: $heard');
  });

  testWidgets('a getDelivery that fails reports refresh_failed', (tester) async {
    final delivery = await release();
    final now = DateTime.now().toUtc();
    delivery['deliveryAccess'] = {
      'urlMode': 'signed',
      'signedUrlExpiresAt': now.add(const Duration(seconds: 16)).toIso8601String(),
      'lastFetchedAt': now.toIso8601String(),
    };
    final heard = Heard();
    await tester.pumpWidget(mascot(heard, delivery: delivery, getDelivery: () async => throw StateError('offline')));
    await until(tester, () => heard.errors.any((e) => e.code == 'refresh_failed'), 'refresh_failed', heard,
        timeout: const Duration(seconds: 20));
  });

  testWidgets('a delivery the player refuses reports why', (tester) async {
    final heard = Heard();
    await tester.pumpWidget(mascot(heard, delivery: 'not a delivery'));
    await until(tester, () => heard.errors.isNotEmpty, 'an error', heard);
    expect(heard.errors.first.code, 'unreadable');
    expect(heard.poses, isEmpty);
  });

  testWidgets('a clip plays one animation on its own', (tester) async {
    final heard = Heard();
    await tester.pumpWidget(mascot(
      heard,
      clip: MaskoClipFiles(hevc: '$server/clips/celebrate.mov', stacked: '$server/clips/celebrate.mp4'),
    ));
    await until(tester, () => heard.clips.isNotEmpty, 'the clip', heard);
    expect(heard.clips.first.kind, MaskoClipKind.pose);
    expect(heard.errors, isEmpty, reason: '$heard');
  });

  testWidgets('plays a release whose links are files on the device', (tester) async {
    final delivery = await releaseOnDevice();
    final heard = Heard();
    final controller = MaskoController();
    await tester.pumpWidget(mascot(heard, delivery: delivery, controller: controller));
    await until(tester, () => heard.sawClip('idle'), 'the idle loop', heard);
    controller.set('working', true);
    await until(tester, () => heard.sawClip('work'), 'the work loop', heard);
    expect(heard.errors, isEmpty, reason: '$heard');
  });

  testWidgets('a clip plays from a file path on the device', (tester) async {
    final folder = await Directory.systemTemp.createTemp('masko-clip');
    final hevc = File('${folder.path}/hi.mov');
    final stacked = File('${folder.path}/hi.mp4');
    await download(Uri.parse('$server/clips/hi.mov'), hevc);
    await download(Uri.parse('$server/clips/hi.mp4'), stacked);
    final heard = Heard();
    await tester.pumpWidget(mascot(heard, clip: MaskoClipFiles(hevc: hevc.path, stacked: stacked.path)));
    await until(tester, () => heard.clips.isNotEmpty, 'the clip', heard);
    expect(heard.errors, isEmpty, reason: '$heard');
  });

  testWidgets("a clip without this platform's file reports clip_failed", (tester) async {
    final heard = Heard();
    await tester.pumpWidget(mascot(heard, clip: const MaskoClipFiles()));
    await until(tester, () => heard.errors.isNotEmpty, 'an error', heard);
    expect(heard.errors.single.code, 'clip_failed');
  });

  testWidgets('a tap on the mascot reaches the app', (tester) async {
    final heard = Heard();
    final controller = MaskoController();
    await tester.pumpWidget(mascot(
      heard,
      delivery: await release(),
      controller: controller,
      onTap: () => controller.fire('click'),
    ));
    await until(tester, () => heard.sawClip('idle'), 'the idle loop', heard);
    await tester.tap(find.byType(GestureDetector));
    await until(tester, () => heard.sawClip('hi'), 'the hi clip', heard);
    // A claimed fire is spent when the clip it started ends (rules.md 3.3).
    await until(tester, () => heard.reactions.isNotEmpty, 'reactionDone', heard);
    expect(heard.reactions.single.name, 'action::click');
    expect(heard.reactions.single.used, isTrue);
  });

  testWidgets('a view taken away reports nothing more', (tester) async {
    final heard = Heard();
    await tester.pumpWidget(mascot(heard, delivery: await release()));
    await until(tester, () => heard.sawClip('idle'), 'the idle loop', heard);
    await tester.pumpWidget(const SizedBox());
    final count = heard.count;
    await wait(tester, const Duration(seconds: 2));
    expect(heard.count, count, reason: '$heard');
  });

  testWidgets('maskoFormats names what this device plays', (tester) async {
    final formats = await maskoFormats();
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      expect(formats, 'av1');
    } else {
      expect(formats, anyOf('av1', ''));
    }
  });
}
