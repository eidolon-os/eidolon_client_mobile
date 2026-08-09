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
