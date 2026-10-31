// The delivery as the native players take it: the delivery object's JSON.

import 'dart:convert';

/// The delivery object inside what the app gave, or the text as given when
/// it is not JSON.
Object? _unwrap(Object input) {
  Object? value = input;
  if (value is String) {
    try {
      value = jsonDecode(value);
    } on FormatException {
      return input;
    }
  }
  for (final key in ['data', 'delivery']) {
    if (value is Map && !value.containsKey('runtimeGraph') && value.containsKey(key)) {
      value = value[key];
    }
  }
  return value;
}

/// The delivery's JSON for the native player. Text that is not JSON goes as
/// is; the player refuses it.
String deliveryJson(Object input) {
  final value = _unwrap(input);
  return value is String ? value : jsonEncode(value);
}

final _link = RegExp(r'^(https?:|blob:|data:|file:)', caseSensitive: false);

/// [value] with every link left out.
Object? _withoutLinks(Object? value) {
  if (value is String) return _link.hasMatch(value) ? '' : value;
  if (value is Map) return value.map((key, v) => MapEntry(key, _withoutLinks(v)));
  if (value is List) return value.map(_withoutLinks).toList();
  return value;
}

/// Which release a delivery is, links left out: a new release loads a new
/// player, new links do not.
String releaseKey(Object input) {
  final value = _unwrap(input);
  if (value is! Map) return '$value';
  final release = value['release'];
  final id = release is Map ? release['id'] : null;
  return jsonEncode([id, _withoutLinks(value['runtimeGraph'])]);
}
