import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_flow.dart';
import 'package:eidolon_client_mobile/src/features/conversation/device_owner_directory.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_device_contexts.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_device_runtime.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/host_controller_device_admission.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_product_controller.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'support/owner_domain_fixtures.dart';
import 'support/phone_identity_fixtures.dart';

class _Admission implements DeviceAdmissionPort {
  @override
  dynamic noSuchMethod(Invocation i) => throw StateError('Not requested');
}

ConversationManagement management() => ConversationManagement(
    controllerId: 'controller',
    admission: _Admission(),
    roster: ({cursor}) => throw StateError('not requested'),
    device: (_) => throw StateError('not requested'),
    assign: (
            {required deviceId,
            required requestId,
            required companionId,
            required expectedRevision}) =>
        throw StateError('not requested'));
DeviceOnboardingTarget target(String owner) => DeviceOnboardingTarget(
    ownerDomainId: owner,
    ownerRootCertificate: ownerRootCertificateFixture,
    authoritySigningCertificate: authoritySigningCertificateFixture,
    ownerDomainDescriptor: OwnerDomainDescriptorV1.fromJson(
        {...ownerDomainDescriptorJsonFixture, 'owner_domain_id': owner}));

class _Controller implements HostProductController {
  bool ready = false;
  int reads = 0;
  @override
  Future<EnrollmentProposalPageV1> listEnrollmentRecovery(
      {AdmissionListCursorV1? after}) async {
    expect(ready, true);
    reads++;
    throw StateError('Reached prepared management');
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw StateError('Not requested');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  MobileDeviceRuntime runtime() {
    final prefs = InMemoryAppPreferences();
    return MobileDeviceRuntime(
        contexts: MobileDeviceContexts(
            preferences: prefs, platform: FakePhonePlatform()),
        directory: DeviceOwnerDirectory(
            preferences: prefs,
            verifier: const AcceptingOwnerDomainDirectoryVerifier()));
  }

  test('A B A retains enrollment state per Owner, not per Host or page',
      () async {
    final r = runtime();
    Future<ConversationFlow> open(String host, String owner) => r.open(
        hostId: host,
        hostName: host,
        bootstrap: () async => target(owner),
        management: management());
    final a = await open('host-a', 'owner-a');
    final b = await open('host-b', 'owner-b');
    final a2 = await open('host-a2', 'owner-a');
    expect(a2.enrollment, same(a.enrollment));
    expect(b.enrollment, isNot(same(a.enrollment)));
    expect(a2.client, isNot(same(a.client)));
    expect(a2.selectedMode, isNull);
    expect(a2.selectedCompanionId, isNull);
    for (final f in [a, b, a2]) {
      await f.close();
      f.dispose();
    }
  });
  test('a delayed old Host open cannot replace a newer selection', () async {
    final r = runtime();
    final slow = Completer<DeviceOnboardingTarget>();
    final a = r.open(
        hostId: 'a',
        hostName: 'a',
        bootstrap: () => slow.future,
        management: management());
    final refused = expectLater(a, throwsStateError);
    final b = await r.open(
        hostId: 'b',
        hostName: 'b',
        bootstrap: () async => target('owner-b'),
        management: management());
    slow.complete(target('owner-a'));
    await refused;
    expect(b.ownerDomainId, 'owner-b');
    await b.close();
    b.dispose();
  });
  test(
      'restored Device trust does not run admission before Host management is ready',
      () async {
    final controller = _Controller();
    final readiness = Completer<void>();
    final admission = HostControllerDeviceAdmission(controller,
        prepare: () => readiness.future);
    final reading = admission.listRecovery();
    final result = expectLater(reading, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(controller.reads, 0);
    controller.ready = true;
    readiness.complete();
    await result;
    expect(controller.reads, 1);
  });
}
