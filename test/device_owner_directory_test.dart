import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eidolon_client_mobile/src/features/conversation/device_owner_directory.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'support/owner_domain_fixtures.dart';

void main() {
  test(
      'cached address survives restart and lost Controller without changing signed directory',
      () async {
    final prefs = InMemoryAppPreferences();
    DeviceOwnerDirectory directory() => DeviceOwnerDirectory(
        preferences: prefs,
        verifier: const AcceptingOwnerDomainDirectoryVerifier());
    final original = deviceOnboardingTargetFixture().reachedAt('192.0.2.10');
    await directory().open(hostId: 'host', bootstrap: () async => original);
    final restored = await directory().open(
        hostId: 'host',
        bootstrap: () async => throw StateError('Controller unavailable'));
    expect(restored.hostAddress, '192.0.2.10');
    expect(restored.ownerDomainDescriptor.toJson(),
        original.ownerDomainDescriptor.toJson());
    expect(restored.ownerRootCertificate, original.ownerRootCertificate);
    expect(restored.addressHints.keys.every((host) => host.endsWith('.local')),
        true);
  });

  testWidgets(
      'a locator completing after startup timeout still updates device routes',
      (tester) async {
    final directory = DeviceOwnerDirectory(
        preferences: InMemoryAppPreferences(),
        verifier: const AcceptingOwnerDomainDirectoryVerifier());
    await directory.open(
        hostId: 'host', bootstrap: () async => deviceOnboardingTargetFixture());
    final locator = Completer<DeviceOnboardingTarget>();
    final opening =
        directory.open(hostId: 'host', bootstrap: () => locator.future);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect((await opening).hostAddress, isNull);
    locator.complete(deviceOnboardingTargetFixture().reachedAt('192.0.2.10'));
    await tester.pump();
    expect(
        (await directory.load(ownerDomainIdFixture)).hostAddress, '192.0.2.10');
  });

  test('installed Owner directory works after Controller authorization is gone',
      () async {
    final prefs = InMemoryAppPreferences();
    DeviceOwnerDirectory runtime() => DeviceOwnerDirectory(
        preferences: prefs,
        verifier: const AcceptingOwnerDomainDirectoryVerifier());
    await runtime().open(
        hostId: 'host', bootstrap: () async => deviceOnboardingTargetFixture());
    final reopened = await runtime().open(
        hostId: 'host',
        bootstrap: () async => throw StateError('Controller revoked'));
    expect(reopened.ownerDomainId, ownerDomainIdFixture);
    expect(reopened.ownerRootCertificate, ownerRootCertificateFixture);
  });
  test(
      'a relocated endpoint uses a verified descriptor with the installed root',
      () async {
    final directory = DeviceOwnerDirectory(
        preferences: InMemoryAppPreferences(),
        verifier: const AcceptingOwnerDomainDirectoryVerifier());
    await directory.open(
        hostId: 'host', bootstrap: () async => deviceOnboardingTargetFixture());
    final changed = DeviceOnboardingTarget(
        ownerDomainId: ownerDomainIdFixture,
        ownerRootCertificate: ownerRootCertificateFixture,
        authoritySigningCertificate: authoritySigningCertificateFixture,
        ownerDomainDescriptor: OwnerDomainDescriptorV1.fromJson({
          ...ownerDomainDescriptorJsonFixture,
          'directory_revision': 8,
          'descriptor_uri':
              'https://relocated.test/api/device-onboarding/v1/descriptor'
        }));
    final result =
        await directory.open(hostId: 'host', bootstrap: () async => changed);
    expect(result.ownerDomainDescriptor.directoryRevision, 8);
    expect(result.ownerRootCertificate, ownerRootCertificateFixture);
  });
  test('Host locator cannot replace installed Device trust', () async {
    final directory = DeviceOwnerDirectory(
        preferences: InMemoryAppPreferences(),
        verifier: const AcceptingOwnerDomainDirectoryVerifier());
    await directory.open(
        hostId: 'host', bootstrap: () async => deviceOnboardingTargetFixture());
    await expectLater(
        directory.open(
            hostId: 'host',
            bootstrap: () async => DeviceOnboardingTarget(
                ownerDomainId: ownerDomainIdFixture,
                ownerDomainDescriptor: ownerDomainDescriptorFixture(),
                ownerRootCertificate: 'replacement-root',
                authoritySigningCertificate:
                    authoritySigningCertificateFixture)),
        throwsFormatException);
  });
  test('expiring directory renews through its public descriptor endpoint',
      () async {
    var requested = false;
    final expiring = DeviceOnboardingTarget(
        ownerDomainId: ownerDomainIdFixture,
        ownerRootCertificate: ownerRootCertificateFixture,
        authoritySigningCertificate: authoritySigningCertificateFixture,
        ownerDomainDescriptor: OwnerDomainDescriptorV1.fromJson({
          ...ownerDomainDescriptorJsonFixture,
          'expires_at': DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 1))
              .toIso8601String()
        }));
    final directory = DeviceOwnerDirectory(
        preferences: InMemoryAppPreferences(),
        verifier: const AcceptingOwnerDomainDirectoryVerifier(),
        transport: (_) => MockClient((request) async {
              requested = true;
              expect(request.method, 'GET');
              expect(request.headers.containsKey('authorization'), false);
              return http.Response(
                  jsonEncode({
                    ...ownerDomainDescriptorJsonFixture,
                    'directory_revision': 8
                  }),
                  200);
            }));
    final result =
        await directory.open(hostId: 'host', bootstrap: () async => expiring);
    expect(requested, true);
    expect(result.ownerDomainDescriptor.directoryRevision, 8);
  });
  test('same Owner through another Host adopts the selected route', () async {
    final prefs = InMemoryAppPreferences();
    final directory = DeviceOwnerDirectory(
        preferences: prefs,
        verifier: const AcceptingOwnerDomainDirectoryVerifier());
    await directory.open(
        hostId: 'host-a',
        bootstrap: () async =>
            deviceOnboardingTargetFixture().reachedAt('192.0.2.1'));
    final b = await directory.open(
        hostId: 'host-b',
        bootstrap: () async =>
            deviceOnboardingTargetFixture().reachedAt('192.0.2.2'));
    expect(b.hostAddress, '192.0.2.2');
    final a = await directory.open(
        hostId: 'host-a', bootstrap: () async => throw StateError('offline'));
    expect(a.hostAddress, '192.0.2.1');
  });

  test('older Host lookup cannot undo a newer selected route', () async {
    final directory = DeviceOwnerDirectory(
        preferences: InMemoryAppPreferences(),
        verifier: const AcceptingOwnerDomainDirectoryVerifier());
    await directory.open(
        hostId: 'a',
        bootstrap: () async =>
            deviceOnboardingTargetFixture().reachedAt('192.0.2.1'));
    final old = Completer<DeviceOnboardingTarget>();
    final opening = directory.open(hostId: 'a', bootstrap: () => old.future);
    await Future<void>.delayed(Duration.zero);
    await directory.open(
        hostId: 'b',
        bootstrap: () async =>
            deviceOnboardingTargetFixture().reachedAt('192.0.2.2'));
    old.complete(deviceOnboardingTargetFixture().reachedAt('192.0.2.9'));
    await opening;
    expect(
        (await directory.load(ownerDomainIdFixture)).hostAddress, '192.0.2.2');
  });

  test('concurrent directory saves retain both Hosts across instances',
      () async {
    final prefs = InMemoryAppPreferences();
    DeviceOwnerDirectory directory() => DeviceOwnerDirectory(
        preferences: prefs,
        verifier: const AcceptingOwnerDomainDirectoryVerifier());
    await Future.wait([
      directory().open(
          hostId: 'a',
          bootstrap: () async =>
              deviceOnboardingTargetFixture().reachedAt('192.0.2.1')),
      directory().open(
          hostId: 'b',
          bootstrap: () async =>
              deviceOnboardingTargetFixture().reachedAt('192.0.2.2')),
    ]);
    for (final host in ['a', 'b']) {
      final restored = await directory().open(
          hostId: host,
          bootstrap: () => throw StateError('must use saved trust'));
      expect(restored.hostAddress, host == 'a' ? '192.0.2.1' : '192.0.2.2');
    }
  });
  test('switching to a cached Host keeps the newest accepted Owner descriptor',
      () async {
    final directory = DeviceOwnerDirectory(
        preferences: InMemoryAppPreferences(),
        verifier: const AcceptingOwnerDomainDirectoryVerifier());
    await directory.open(
        hostId: 'a',
        bootstrap: () async =>
            deviceOnboardingTargetFixture().reachedAt('192.0.2.1'));
    final latest = DeviceOnboardingTarget(
        ownerDomainId: ownerDomainIdFixture,
        ownerRootCertificate: ownerRootCertificateFixture,
        authoritySigningCertificate: authoritySigningCertificateFixture,
        ownerDomainDescriptor: OwnerDomainDescriptorV1.fromJson(
            {...ownerDomainDescriptorJsonFixture, 'directory_revision': 9}),
        hostAddress: '192.0.2.2');
    await directory.open(hostId: 'b', bootstrap: () async => latest);
    final a = await directory.open(
        hostId: 'a', bootstrap: () => throw StateError('offline Controller'));
    expect(a.ownerDomainDescriptor.directoryRevision, 9);
    expect(a.hostAddress, '192.0.2.1');
  });
}
