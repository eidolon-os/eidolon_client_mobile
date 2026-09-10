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
  test(
      'renaming and observations preserve each other and never revive a removed Host',
      () async {
    final prefs = InMemoryAppPreferences();
    final a = PlatformHostRegistry(preferences: prefs);
    final b = PlatformHostRegistry(preferences: prefs);
    final host = _host('1');
    await a.save(host);
    await Future.wait([
      a.rename(host.hostId, '书房'),
      b.updateObservation(host.copyWith(
          lastKnownBaseUrl: 'https://192.168.1.99:9002',
          lastConnectedAt: DateTime.utc(2026, 9, 10))),
    ]);
    final renamed = (await a.load()).single;
    expect(renamed.displayName, '书房');
    expect(renamed.lastKnownBaseUrl, 'https://192.168.1.99:9002');
    expect(renamed.controllerId, host.controllerId);
    await a.remove(host.hostId);
    await b.rename(host.hostId, '不能复活');
    expect(await a.load(), isEmpty);
  });

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
  test('different registry instances serialize writes to the same preferences',
      () async {
    final prefs = InMemoryAppPreferences();
    await Future.wait([
      PlatformHostRegistry(preferences: prefs).save(_host('1')),
      PlatformHostRegistry(preferences: prefs).save(_host('2')),
    ]);
    expect(await PlatformHostRegistry(preferences: prefs).load(), hasLength(2));
  });

  test(
      'late Host observations cannot undo rename, newer route, removal or reclaim',
      () async {
    final registry =
        PlatformHostRegistry(preferences: InMemoryAppPreferences());
    final original = _host('1');
    await registry.save(original);
    final newer = original.copyWith(
        displayName: '我的主机',
        lastKnownBaseUrl: 'https://192.0.2.2',
        lastConnectedAt: DateTime.utc(2026, 9, 10));
    await registry.save(newer);
    final result = await registry.updateObservation(original.copyWith(
        lastKnownBaseUrl: 'https://192.0.2.1',
        lastConnectedAt: DateTime.utc(2026, 9, 9)));
    expect(result!.displayName, '我的主机');
    expect(result.lastKnownBaseUrl, 'https://192.0.2.2');
    await registry.remove(original.hostId);
    expect(await registry.updateObservation(original), isNull);
    expect(await registry.load(), isEmpty);
    await registry.save(_host('1', minute: 4));
    expect(await registry.updateObservation(original), isNull);
    expect((await registry.load()).single.claimedAt.minute, 4);
  });
}
