import 'dart:async';
import 'dart:convert';

import '../../platform/app_preferences.dart';
import 'device_setup_models.dart';
import 'device_setup_ports.dart';

/// Persists only the non-secret Device Setup state required for forward
/// recovery. Wi-Fi credentials and pairing material are never accepted by the
/// checkpoint model and therefore cannot enter this document.
class PersistentDeviceSetupCheckpointStore
    implements DeviceSetupCheckpointStore {
  PersistentDeviceSetupCheckpointStore({
    AppPreferences? preferences,
    this.maximumEntries = 32,
  }) : _preferences = preferences ?? PlatformAppPreferences() {
    if (maximumEntries <= 0) {
      throw ArgumentError.value(
        maximumEntries,
        'maximumEntries',
        'must be positive',
      );
    }
  }

  static const _preferenceKey = 'eidolon.device-setup-checkpoints.v2';
  static const _documentVersion = '2';

  final AppPreferences _preferences;
  final int maximumEntries;
  Future<void> _writeQueue = Future<void>.value();

  @override
  Future<DeviceSetupCheckpoint?> load(String setupId) async {
    _validateSetupId(setupId);
    await _writeQueue;
    final entries = await _readEntries();
    return entries.where((item) => item.setupId == setupId).firstOrNull;
  }

  @override
  Future<void> remove(String setupId) {
    _validateSetupId(setupId);
    return _enqueueWrite(() async {
      final entries = await _readEntries();
      entries.removeWhere((item) => item.setupId == setupId);
      await _writeEntries(entries);
    });
  }

  @override
  Future<void> save(DeviceSetupCheckpoint checkpoint) {
    _validateSetupId(checkpoint.setupId);
    if (checkpoint.contractVersion !=
        DeviceSetupCheckpoint.currentContractVersion) {
      throw const FormatException('Unsupported Device Setup checkpoint');
    }
    return _enqueueWrite(() async {
      final entries = await _readEntries();
      entries
        ..removeWhere((item) => item.setupId == checkpoint.setupId)
        ..add(checkpoint);
      entries.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
      await _writeEntries(entries.take(maximumEntries).toList());
    });
  }

  Future<List<DeviceSetupCheckpoint>> _readEntries() async {
    final raw = await _preferences.readString(_preferenceKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final document = jsonDecode(raw);
      if (document is! Map ||
          document['contract_version'] != _documentVersion ||
          document['checkpoints'] is! List) {
        return [];
      }
      final result = <DeviceSetupCheckpoint>[];
      final seen = <String>{};
      for (final value in document['checkpoints'] as List) {
        if (value is! Map) continue;
        try {
          final checkpoint = DeviceSetupCheckpoint.fromJson(
            Map<String, dynamic>.from(value),
          );
          if (seen.add(checkpoint.setupId)) result.add(checkpoint);
        } catch (_) {
          // Corruption is isolated to one setup; valid recovery state remains.
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeEntries(List<DeviceSetupCheckpoint> entries) =>
      _preferences.writeString(
        _preferenceKey,
        jsonEncode({
          'contract_version': _documentVersion,
          'checkpoints': entries.map((item) => item.toJson()).toList(),
        }),
      );

  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final result = _writeQueue.then((_) => operation());
    _writeQueue = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  void _validateSetupId(String setupId) {
    if (setupId.isEmpty || setupId.length > 128) {
      throw const FormatException('Invalid Device Setup ID');
    }
  }
}
