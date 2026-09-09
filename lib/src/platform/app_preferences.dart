import 'dart:async';

import 'package:flutter/services.dart';

abstract interface class AppPreferences {
  Future<String?> readString(String key);

  Future<void> writeString(String key, String value);
}

class PlatformAppPreferences implements AppPreferences {
  PlatformAppPreferences({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform');

  final MethodChannel _channel;

  @override
  Future<String?> readString(String key) => _channel.invokeMethod<String>(
        'readAppPreference',
        {'key': key},
      );

  @override
  Future<void> writeString(String key, String value) =>
      _channel.invokeMethod<void>(
        'writeAppPreference',
        {'key': key, 'value': value},
      );
}

class InMemoryAppPreferences implements AppPreferences {
  final Map<String, String> _values = {};

  @override
  Future<String?> readString(String key) async => _values[key];

  @override
  Future<void> writeString(String key, String value) async {
    _values[key] = value;
  }
}

/// Serialize read/modify/write operations on one persisted document, including
/// writers owned by different pages. Finished operations retain no queue state.
class PreferenceWrites {
  static final Map<Object, Future<void>> _pending = {};

  static Future<T> run<T>(AppPreferences preferences, String key,
      Future<T> Function() action) async {
    final scope =
        (preferences is PlatformAppPreferences ? null : preferences, key);
    final previous = _pending[scope];
    final done = Completer<void>();
    _pending[scope] = done.future;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      if (identical(_pending[scope], done.future)) _pending.remove(scope);
      done.complete();
    }
  }
}
