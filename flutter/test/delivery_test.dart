import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:masko_player/src/delivery.dart';

Map<String, Object?> delivery({String release = 'r1', String link = 'https://cdn.example/a.mov?sig=1'}) => {
      'deliverySchemaVersion': 1,
      'release': {'id': release},
      'runtimeGraph': {
        'initialNode': 'idle',
        'edges': [
          {
            'id': 'idle',
            'videos': {'hevc': link},
          },
        ],
      },
    };

void main() {
  group('deliveryJson', () {
    test('takes the delivery, its JSON, or the API response around it', () {
      final expected = jsonEncode(delivery());
      expect(deliveryJson(delivery()), expected);
      expect(deliveryJson(jsonEncode(delivery())), expected);
      expect(deliveryJson({'delivery': delivery()}), expected);
      expect(deliveryJson({
        'data': {'delivery': delivery()},
      }), expected);
      expect(deliveryJson(jsonEncode({
        'data': {'delivery': delivery()},
      })), expected);
    });

    test('passes text that is not JSON as is, for the player to refuse', () {
      expect(deliveryJson('not a delivery'), 'not a delivery');
    });
  });

  group('releaseKey', () {
    test('leaves links out: new links of the same release keep the key', () {
      expect(
        releaseKey(delivery(link: 'https://cdn.example/a.mov?sig=2')),
        releaseKey({
          'data': {'delivery': delivery()},
        }),
      );
      expect(releaseKey(delivery(link: 'file:///tmp/a.mov')), releaseKey(delivery()));
    });

    test('changes with the release or its graph', () {
      expect(releaseKey(delivery(release: 'r2')), isNot(releaseKey(delivery())));
      final other = delivery();
      (other['runtimeGraph']! as Map)['initialNode'] = 'working';
      expect(releaseKey(other), isNot(releaseKey(delivery())));
    });
  });
}
