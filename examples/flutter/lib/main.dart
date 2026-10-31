// Plays the example release (../react-native/server/serve.mjs) with the
// calls an app makes: set, fire, sound, pause and play, reset and position,
// a tap on the mascot, and a log of every event. The server also relays
// commands from a terminal, so a test can drive it:
// `curl -X POST localhost:47290/do/fire/celebrate`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:masko_player/masko_player.dart';

/// The clip server: this computer, as the simulator or the emulator reaches it.
String get server {
  const given = String.fromEnvironment('MASKO_CLIPS_URL');
  if (given.isNotEmpty) return given;
  return defaultTargetPlatform == TargetPlatform.android ? 'http://10.0.2.2:47290' : 'http://localhost:47290';
}

/// GETs [path] from the clip server as text; '' when it has nothing (204).
Future<String> fetchText(String path, {Duration timeout = const Duration(seconds: 10)}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('$server$path')).timeout(timeout);
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode == 204) return '';
    if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
    return body;
  } finally {
    client.close(force: true);
  }
}

/// The example release, as the API gives it: `{data: {delivery}}`.
Future<Map<String, Object?>> fetchDelivery() async =>
    (jsonDecode(await fetchText('/delivery.json')) as Map).cast<String, Object?>();

void main() => runApp(const MaterialApp(home: ExamplePage()));

class ExamplePage extends StatefulWidget {
  const ExamplePage({super.key});

  @override
  State<ExamplePage> createState() => _ExamplePageState();
}

class _ExamplePageState extends State<ExamplePage> {
  final mascot = MaskoController();
  Object? delivery;
  String? failure;
  bool working = false;
  bool sound = false;
  bool paused = false;
  String pose = 'none';
  String clip = 'none';
  final List<String> log = [];
  bool live = true;

  @override
  void initState() {
    super.initState();
    load();
    relay();
  }

  @override
  void dispose() {
    live = false;
    super.dispose();
  }

  void note(String line) {
    // Also in the device log (flutter logs).
    debugPrint('[masko-example] $line');
    if (!mounted) return;
    final time = DateTime.now().toIso8601String().substring(14, 23);
    setState(() {
      log.insert(0, '$time $line');
      if (log.length > 16) log.removeLast();
    });
  }

  void load() {
    setState(() => failure = null);
    fetchDelivery().then(
      (fresh) => setState(() => delivery = fresh),
      onError: (Object e) => setState(() => failure = '$server: $e'),
    );
  }

  /// A new delivery: fresh links of the same release, which the view hands
  /// to the player's updateDelivery.
  void reload() {
    fetchDelivery().then(
      (fresh) {
        setState(() => delivery = fresh);
        note('delivery prop');
      },
      onError: (Object e) => note('delivery prop failed $e'),
    );
  }

  void set(String name, Object value) {
    mascot.set(name, value);
    if (name == 'working') setState(() => working = value == true);
    note('set $name $value');
  }

  void fire(String name) {
    mascot.fire(name);
    note('fire $name');
  }

  void reset() {
    mascot.reset();
    setState(() => working = false);
    note('reset');
  }

  void setPaused(bool on) {
    setState(() => paused = on);
    on ? mascot.pause() : mascot.play();
  }

  Future<void> showPosition() async {
    final at = await mascot.position();
    note('position ${at.clip ?? 'none'} ${at.time.toStringAsFixed(3)}s');
  }

  /// Commands relayed by the server: set/working/true, fire/celebrate,
  /// sound/on, pause, play, reset, position, delivery.
  void run(String command) {
    final parts = command.split('/');
    final verb = parts[0];
    final name = parts.length > 1 ? parts[1] : '';
    final value = parts.length > 2 ? parts[2] : '';
    if (verb == 'set' && name.isNotEmpty) {
      set(name, value == 'true' ? true : (value == 'false' ? false : num.parse(value)));
    }
    if (verb == 'fire' && name.isNotEmpty) fire(name);
    if (verb == 'sound') setState(() => sound = name == 'on');
    if (verb == 'pause') setPaused(true);
    if (verb == 'play') setPaused(false);
    if (verb == 'reset') reset();
    if (verb == 'position') showPosition();
    if (verb == 'delivery') reload();
  }

  Future<void> relay() async {
    while (live) {
      try {
        final command = await fetchText('/next', timeout: const Duration(seconds: 25));
        if (live && command.isNotEmpty) run(command);
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mono = TextStyle(
      fontFamily: defaultTargetPlatform == TargetPlatform.iOS ? 'Menlo' : 'monospace',
      fontSize: 12,
      color: const Color(0xFF1D1B19),
    );
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              const Text(
                'Masko player',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Color(0xFF1D1B19)),
              ),
              Text('pose $pose / clip $clip', style: const TextStyle(fontSize: 14, color: Color(0xFF686460))),
              const SizedBox(height: 12),
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 240,
                    height: 240,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        const Positioned.fill(child: Checkerboard()),
                        if (delivery != null)
                          GestureDetector(
                            onTap: () => fire('click'),
                            child: SizedBox(
                              width: 220,
                              height: 220,
                              child: MaskoView(
                                controller: mascot,
                                delivery: delivery,
                                sound: sound,
                                getDelivery: () {
                                  note('getDelivery');
                                  return fetchDelivery();
                                },
                                onPose: (p) {
                                  setState(() => pose = p);
                                  note('pose $p');
                                },
                                onClip: (e) {
                                  setState(() => clip = e.clip);
                                  note('clip ${e.clip} ${e.kind.name} x${e.rate}');
                                },
                                onReactionDone: (e) => note('reactionDone ${e.name} ${e.used ? 'used' : 'unused'}'),
                                onMovement: (e) =>
                                    note('movement ${e.edge} ${jsonEncode(e.movement)} x${e.rate} ${e.seconds}s'),
                                onError: (e) => note('error ${e.code}${e.detail == null ? '' : ' ${e.detail}'}'),
                              ),
                            ),
                          )
                        else
                          GestureDetector(
                            onTap: load,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                failure == null ? 'Loading' : '$failure\nStart the clip server, then tap to retry.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Color(0xFF686460)),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Button(working ? 'Working: on' : 'Working: off', () => set('working', !working)),
                  _Button('Celebrate', () => fire('celebrate')),
                  _Button(sound ? 'Sound: on' : 'Sound: off', () => setState(() => sound = !sound)),
                  _Button(paused ? 'Play' : 'Pause', () => setPaused(!paused)),
                  _Button('Reset', reset),
                  _Button('Position', showPosition),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: const Color(0xFFF7F6F5), borderRadius: BorderRadius.circular(8)),
                  child: ListView(children: [for (final line in log) Text(line, style: mono)]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button(this.label, this.onPressed);

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFF95D02),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: onPressed,
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      );
}

/// Squares behind the mascot, so its transparency shows.
class Checkerboard extends StatelessWidget {
  const Checkerboard({super.key});

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _Squares());
}

class _Squares extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF7F6F5));
    final square = Paint()..color = const Color(0xFFE4E0DC);
    for (var row = 0; row * 30 < size.height; row++) {
      for (var col = 0; col * 30 < size.width; col++) {
        if ((row + col).isEven) canvas.drawRect(Rect.fromLTWH(col * 30.0, row * 30.0, 30, 30), square);
      }
    }
  }

  @override
  bool shouldRepaint(_Squares old) => false;
}
