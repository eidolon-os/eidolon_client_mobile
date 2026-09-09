import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eidolon_client_mobile/src/features/conversation/device_owner_directory.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'support/owner_domain_fixtures.dart';

void main() {
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
}
