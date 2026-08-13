import 'dart:convert';

import '../../platform/app_preferences.dart';
import 'host_identity.dart';

class ManagedHost {
  const ManagedHost({
    required this.hostId,
    required this.hostPublicKey,
    required this.hostFingerprint,
    required this.bleServiceUuid,
    required this.controllerId,
    required this.displayName,
    required this.claimedAt,
    this.tlsSpkiFingerprint,
  });

  factory ManagedHost.fromJson(Map<String, dynamic> value) => ManagedHost(
        hostId: value['host_id']! as String,
        hostPublicKey: value['host_public_key']! as String,
        hostFingerprint: value['host_fingerprint']! as String,
        bleServiceUuid: value['ble_service_uuid']! as String,
        controllerId: value['controller_id']! as String,
        displayName: normalizeHostDisplayName(
          value['host_id']! as String,
          value['display_name']! as String,
        ),
        claimedAt: DateTime.parse(value['claimed_at']! as String).toUtc(),
        tlsSpkiFingerprint: _optionalTlsFingerprint(
          value['tls_spki_fingerprint'],
        ),
      );

  final String hostId;
  final String hostPublicKey;
  final String hostFingerprint;
  final String bleServiceUuid;
  final String controllerId;
  final String displayName;
  final DateTime claimedAt;
  final String? tlsSpkiFingerprint;

  ManagedHost copyWith({String? tlsSpkiFingerprint}) => ManagedHost(
        hostId: hostId,
        hostPublicKey: hostPublicKey,
        hostFingerprint: hostFingerprint,
        bleServiceUuid: bleServiceUuid,
        controllerId: controllerId,
        displayName: displayName,
        claimedAt: claimedAt,
        tlsSpkiFingerprint: tlsSpkiFingerprint ?? this.tlsSpkiFingerprint,
      );

  Map<String, dynamic> toJson() => {
        'host_id': hostId,
        'host_public_key': hostPublicKey,
        'host_fingerprint': hostFingerprint,
        'ble_service_uuid': bleServiceUuid,
        'controller_id': controllerId,
        'display_name': displayName,
        'claimed_at': claimedAt.toUtc().toIso8601String(),
        if (tlsSpkiFingerprint != null)
          'tls_spki_fingerprint': tlsSpkiFingerprint,
      };
}

String? _optionalTlsFingerprint(Object? value) {
  if (value == null) return null;
  if (value is! String ||
      !RegExp(r'^sha256:[A-Za-z0-9_-]{43}$').hasMatch(value)) {
    throw const FormatException('Invalid Host TLS SPKI fingerprint');
  }
  return value;
}

abstract interface class HostRegistry {
  Future<List<ManagedHost>> load();

  Future<void> save(ManagedHost host);

  /// Forget a Host on this phone. Nothing is asked of the Host: it may be
  /// gone, or replaced by a reinstall, and either way this list is the only
  /// place the entry exists.
  Future<void> remove(String hostId);
}

class PlatformHostRegistry implements HostRegistry {
  static const _key = 'eidolon.managed-hosts.v1';
  static const _maximumHosts = 16;

  PlatformHostRegistry({AppPreferences? preferences})
      : _preferences = preferences ?? PlatformAppPreferences();

  final AppPreferences _preferences;
  Future<void> _writeQueue = Future<void>.value();

  @override
  Future<List<ManagedHost>> load() async {
    final raw = await _preferences.readString(_key);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final hosts = <ManagedHost>[];
      final seen = <String>{};
      for (final value in decoded) {
        if (value is! Map) continue;
        try {
          final host = ManagedHost.fromJson(Map<String, dynamic>.from(value));
          if (seen.add(host.hostId)) hosts.add(host);
        } catch (_) {
          // One malformed entry must not erase every valid saved Host.
        }
      }
      return hosts.take(_maximumHosts).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> save(ManagedHost host) {
    final result = _writeQueue.then((_) async {
      final current = await load();
      final next = [
        host,
        ...current.where((item) => item.hostId != host.hostId),
      ].take(_maximumHosts);
      await _preferences.writeString(
        _key,
        jsonEncode(next.map((item) => item.toJson()).toList()),
      );
    });
    _writeQueue = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  @override
  Future<void> remove(String hostId) {
    final result = _writeQueue.then((_) async {
      final current = await load();
      final next = current.where((item) => item.hostId != hostId);
      await _preferences.writeString(
        _key,
        jsonEncode(next.map((item) => item.toJson()).toList()),
      );
    });
    _writeQueue = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }
}

class InMemoryHostRegistry implements HostRegistry {
  InMemoryHostRegistry([Iterable<ManagedHost> initial = const []])
      : _hosts = List.of(initial);

  final List<ManagedHost> _hosts;

  @override
  Future<List<ManagedHost>> load() async => List.unmodifiable(_hosts);

  @override
  Future<void> save(ManagedHost host) async {
    _hosts
      ..removeWhere((item) => item.hostId == host.hostId)
      ..insert(0, host);
  }

  @override
  Future<void> remove(String hostId) async {
    _hosts.removeWhere((item) => item.hostId == hostId);
  }
}
