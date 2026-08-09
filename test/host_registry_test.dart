import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/setup_fixtures.dart';

const _preferenceKey = 'eidolon.managed-hosts.v1';

ManagedHost _host(String suffix, {int minute = 0}) => ManagedHost(
      hostId: 'ehost-${suffix.padLeft(20, '0')}',
      hostPublicKey: validHostPublicKey,
      hostFingerprint: validHostPublicKeyFingerprint,
      bleServiceUuid: validBleServiceUuid,
      controllerId: 'ectrl-0123456789abcdefabcd',
      displayName: 'Eidolon $suffix',
      claimedAt: DateTime.utc(2026, 8, 9, 10, minute),
      tlsSpkiFingerprint: 'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8',
    );

void main() {
  test('one malformed entry does not erase valid managed Hosts', () async {
    final preferences = InMemoryAppPreferences();
    await preferences.writeString(
      _preferenceKey,
      jsonEncode([
        {'host_id': 42},
        _host('1').toJson(),
      ]),
    );

    final loaded = await PlatformHostRegistry(
      preferences: preferences,
    ).load();

    expect(loaded, hasLength(1));
    expect(loaded.single.hostId, 'ehost-00000000000000000001');
  });

  test('concurrent saves preserve every Host and replace duplicates', () async {
    final preferences = InMemoryAppPreferences();
    final registry = PlatformHostRegistry(preferences: preferences);

    await Future.wait([
      registry.save(_host('1')),
      registry.save(_host('2')),
      registry.save(_host('3')),
    ]);
    await registry.save(_host('2', minute: 5));
    final loaded = await registry.load();

    expect(loaded.map((item) => item.hostId).toSet(), hasLength(3));
    expect(loaded.first.hostId, 'ehost-00000000000000000002');
    expect(loaded.first.claimedAt.minute, 5);
  });
}
