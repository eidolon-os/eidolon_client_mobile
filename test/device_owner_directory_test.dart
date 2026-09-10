import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eidolon_client_mobile/src/features/conversation/device_owner_directory.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'support/owner_domain_fixtures.dart';

const _key = 'eidolon.device-owner-directory.v1';
DeviceOnboardingTarget _target(Map<String, dynamic> changes) =>
    DeviceOnboardingTarget(
      ownerDomainId: ownerDomainIdFixture,
      ownerRootCertificate: ownerRootCertificateFixture,
      authoritySigningCertificate: authoritySigningCertificateFixture,
      ownerDomainDescriptor: OwnerDomainDescriptorV1.fromJson({
        ...ownerDomainDescriptorJsonFixture,
        ...changes,
      }),
    );

void main() {
  late InMemoryAppPreferences prefs;
  DeviceOwnerDirectory directory(
      {http.Client Function(DeviceOnboardingTarget)? transport}) {
    final result = DeviceOwnerDirectory(
      preferences: prefs,
      verifier: const AcceptingOwnerDomainDirectoryVerifier(),
      transport:
          transport ?? (_) => MockClient((_) async => http.Response('', 503)),
    );
    addTearDown(result.close);
    return result;
  }

  setUp(() => prefs = InMemoryAppPreferences());

  test(
      'legacy location is discarded while installed trust survives Controller revocation',
      () async {
    final original = deviceOnboardingTargetFixture();
    await directory().open(hostId: 'host', bootstrap: () async => original);
    final saved =
        jsonDecode((await prefs.readString(_key))!) as Map<String, dynamic>;
    saved['host']['last_reached_address'] = '192.168.100.19';
    await prefs.writeString(_key, jsonEncode(saved));
    var bootstraps = 0;
    final restored = await directory().open(
        hostId: 'host',
        bootstrap: () async {
          bootstraps++;
          throw StateError('Controller revoked');
        });
    expect(bootstraps, 0);
    expect(restored.ownerDomainDescriptor.toJson(),
        original.ownerDomainDescriptor.toJson());
    expect(restored.ownerRootCertificate, original.ownerRootCertificate);
    expect((await prefs.readString(_key))!,
        isNot(contains('last_reached_address')));
  });

  test('cached trust refreshes only from the signed public endpoint', () async {
    final first = directory();
    await first.open(
        hostId: 'host', bootstrap: () async => deviceOnboardingTargetFixture());
    final next = directory(
        transport: (_) => MockClient((request) async {
              expect(request.method, 'GET');
              expect(request.url.toString(),
                  ownerDomainDescriptorJsonFixture['descriptor_uri']);
              expect(request.headers.containsKey('authorization'), false);
              return http.Response(
                  jsonEncode({
                    ...ownerDomainDescriptorJsonFixture,
                    'directory_revision': 8,
                    'descriptor_uri':
                        'https://relocated.test/api/device-onboarding/v1/descriptor',
                  }),
                  200);
            }));
    final result = await next.open(
        hostId: 'host',
        bootstrap: () => throw StateError('must not need Controller'));
    expect(result.ownerDomainDescriptor.directoryRevision, 8);
    expect(result.ownerRootCertificate, ownerRootCertificateFixture);
  });

  test('another Host cannot replace installed Owner trust', () async {
    final store = directory();
    await store.open(
        hostId: 'a', bootstrap: () async => deviceOnboardingTargetFixture());
    await expectLater(
        store.open(
            hostId: 'b',
            bootstrap: () async => DeviceOnboardingTarget(
                  ownerDomainId: ownerDomainIdFixture,
                  ownerDomainDescriptor: ownerDomainDescriptorFixture(),
                  ownerRootCertificate: 'replacement-root',
                  authoritySigningCertificate:
                      authoritySigningCertificateFixture,
                )),
        throwsFormatException);
  });

  test('expiring directory renews through its public endpoint', () async {
    final store = directory(
        transport: (_) => MockClient((request) async => http.Response(
            jsonEncode(
                {...ownerDomainDescriptorJsonFixture, 'directory_revision': 8}),
            200)));
    final result = await store.open(
        hostId: 'host',
        bootstrap: () async => _target({
              'expires_at': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 1))
                  .toIso8601String(),
            }));
    expect(result.ownerDomainDescriptor.directoryRevision, 8);
  });

  test('expired cached directory never falls back when renewal fails',
      () async {
    final store = directory();
    await store.open(
        hostId: 'host', bootstrap: () async => deviceOnboardingTargetFixture());
    final saved =
        jsonDecode((await prefs.readString(_key))!) as Map<String, dynamic>;
    saved['host']['owner_domain_descriptor']['expires_at'] = DateTime.now()
        .toUtc()
        .subtract(const Duration(minutes: 1))
        .toIso8601String();
    await prefs.writeString(_key, jsonEncode(saved));
    await expectLater(
        directory()
            .open(hostId: 'host', bootstrap: () => throw StateError('revoked')),
        throwsStateError);
  });

  test('public refresh cannot change the Owner identity', () async {
    await directory().open(
        hostId: 'host', bootstrap: () async => deviceOnboardingTargetFixture());
    final store = directory(
        transport: (_) => MockClient((_) async => http.Response(
            jsonEncode({
              ...ownerDomainDescriptorJsonFixture,
              'owner_domain_id': 'impostor'
            }),
            200)));
    final result = await store.open(
        hostId: 'host', bootstrap: () => throw StateError('revoked'));
    expect(result.ownerDomainId, ownerDomainIdFixture);
    expect(result.ownerDomainDescriptor.directoryRevision, 7);
  });

  test('concurrent saves retain both Hosts without separate address records',
      () async {
    await Future.wait([
      for (final host in ['a', 'b'])
        directory().open(
            hostId: host,
            bootstrap: () async => deviceOnboardingTargetFixture()),
    ]);
    final saved = jsonDecode((await prefs.readString(_key))!) as Map;
    expect(saved.keys, unorderedEquals(['a', 'b']));
    for (final host in ['a', 'b']) {
      final restored = await directory().open(
          hostId: host, bootstrap: () => throw StateError('saved trust only'));
      expect(restored.ownerDomainId, ownerDomainIdFixture);
    }
  });

  test('returning to cached Host keeps newest accepted Owner descriptor',
      () async {
    final store = directory(
        transport: (_) => MockClient((_) async =>
            http.Response(jsonEncode(ownerDomainDescriptorJsonFixture), 200)));
    await store.open(
        hostId: 'a', bootstrap: () async => deviceOnboardingTargetFixture());
    await store.open(
        hostId: 'b', bootstrap: () async => _target({'directory_revision': 9}));
    final result = await store.open(
        hostId: 'a', bootstrap: () => throw StateError('offline Controller'));
    expect(result.ownerDomainDescriptor.directoryRevision, 9);
  });

  test(
      'cached contents still pass signature validation even when refresh fails',
      () async {
    await directory().open(
        hostId: 'host', bootstrap: () async => deviceOnboardingTargetFixture());
    final store = DeviceOwnerDirectory(
        preferences: prefs,
        verifier: const RejectingOwnerDomainDirectoryVerifier(),
        transport: (_) => MockClient((_) async => http.Response('', 503)));
    addTearDown(store.close);
    await expectLater(
        store.open(
            hostId: 'host', bootstrap: () => throw StateError('revoked')),
        throwsFormatException);
  });
}
