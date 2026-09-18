import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eidolon_client_mobile/src/features/conversation/device_owner_directory.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/owner_domain_directory_verifier.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_product_controller.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/network_changes.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_settings_page.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'support/host_session_fixtures.dart';
import 'support/owner_domain_fixtures.dart';

DeviceOnboardingTarget target(int generation,
        {String domain = ownerDomainIdFixture,
        String root = ownerRootCertificateFixture}) =>
    DeviceOnboardingTarget(
      ownerDomainId: domain,
      ownerRootCertificate: root,
      authoritySigningCertificate: authoritySigningCertificateFixture,
      ownerDomainDescriptor: OwnerDomainDescriptorV1.fromJson({
        ...ownerDomainDescriptorJsonFixture,
        'owner_domain_id': domain,
        'owner_domain_generation': generation,
      }),
    );

class _Signatures implements OwnerDomainSignatureVerifierPort {
  @override
  Future<void> verify(
      {required DeviceOnboardingTarget target,
      required String canonicalSigningDocument}) async {}
}

class _Network implements NetworkChanges {
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<void> close() async {}
}

class _Controller extends HostProductController {
  _Controller(this.offered)
      : super(
            host: hostFixture(),
            onHostUpdated: (_) async {},
            transport: NoopTransport(),
            controllerKeys: FakeControllerKeys(),
            networkChanges: _Network());
  final DeviceOnboardingTarget offered;
  @override
  Future<DeviceOnboardingTarget> fetchDeviceOnboardingTarget() async => offered;
}

void main() {
  late InMemoryAppPreferences prefs;
  late PlatformOwnerDomainDirectoryVerifier verifier;
  late DeviceOwnerDirectory directory;
  http.Client Function(DeviceOnboardingTarget)? transport;
  setUp(() {
    prefs = InMemoryAppPreferences();
    verifier = PlatformOwnerDomainDirectoryVerifier(
        preferences: prefs, signatureVerifier: _Signatures());
    transport = null;
    directory = DeviceOwnerDirectory(
        preferences: prefs,
        verifier: verifier,
        transport: (t) =>
            transport?.call(t) ??
            MockClient((_) async => http.Response('', 503)));
  });
  tearDown(() => directory.close());

  test(
      'forgetting the last Host clears the live cache and permits a fresh bootstrap',
      () async {
    await directory.open(hostId: 'a', bootstrap: () async => target(2));
    await directory.forgetHost('a');
    final result =
        await directory.open(hostId: 'a', bootstrap: () async => target(1));
    expect(result.ownerDomainDescriptor.ownerDomainGeneration, 1);
    await verifier.verify(target(1));
  });

  test('forgetting one Host preserves the other Host and shared domain fence',
      () async {
    await directory.open(hostId: 'a', bootstrap: () async => target(2));
    await directory.open(hostId: 'b', bootstrap: () async => target(2));
    await directory.forgetHost('a');
    expect(await directory.ownerDomainOf('a'), isNull);
    expect(await directory.ownerDomainOf('b'), ownerDomainIdFixture);
    expect(
        (await directory.load(ownerDomainIdFixture))
            .ownerDomainDescriptor
            .ownerDomainGeneration,
        2);
    await expectLater(verifier.verify(target(1)),
        throwsA(isA<OwnerDomainGenerationRollback>()));
  });

  test(
      'realignment installs the confirmed directory for all Hosts and survives restart',
      () async {
    await directory.open(hostId: 'a', bootstrap: () async => target(2));
    await directory.open(hostId: 'b', bootstrap: () async => target(2));
    await verifier.verify(target(5, domain: 'other'));
    await directory.realignOwnerDomain(target(1));
    expect(
        (await directory.load(ownerDomainIdFixture))
            .ownerDomainDescriptor
            .ownerDomainGeneration,
        1);
    final restored = DeviceOwnerDirectory(
        preferences: prefs,
        verifier: verifier,
        transport: (_) => MockClient((_) async => http.Response('', 503)));
    addTearDown(restored.close);
    for (final host in ['a', 'b']) {
      final value = await restored.open(
          hostId: host,
          bootstrap: () => throw StateError('must retain installed trust'));
      expect(value.ownerDomainDescriptor.ownerDomainGeneration, 1);
    }
    await expectLater(verifier.verify(target(4, domain: 'other')),
        throwsA(isA<OwnerDomainGenerationRollback>()));
  });

  test('realignment never replaces the installed Owner root', () async {
    await directory.open(hostId: 'a', bootstrap: () async => target(2));
    await expectLater(
        directory.realignOwnerDomain(target(1, root: 'different-root')),
        throwsFormatException);
    await expectLater(verifier.verify(target(1)),
        throwsA(isA<OwnerDomainGenerationRollback>()));
  });

  test('an outstanding old refresh cannot undo an accepted reset', () async {
    await directory.open(hostId: 'a', bootstrap: () async => target(2));
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    transport = (_) => MockClient((_) {
          requested.complete();
          return response.future;
        });
    final refresh = directory.load(ownerDomainIdFixture, refresh: true);
    final rejected = expectLater(refresh, throwsStateError);
    await requested.future;
    await directory.realignOwnerDomain(target(1));
    response.complete(http.Response(
        jsonEncode(target(2).ownerDomainDescriptor.toJson()), 200));
    await rejected;
    expect(
        (await directory.load(ownerDomainIdFixture))
            .ownerDomainDescriptor
            .ownerDomainGeneration,
        1);
    await verifier.verify(target(1));
  });

  Future<void> showSettings(WidgetTester tester,
      {bool failVerify = false, bool failSave = false}) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _Controller(target(1));
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: HostSettingsPage(
      host: controller.host,
      controller: controller,
      onHostUpdated: (_) async {},
      onHostRenamed: (_) async {},
      onHostRemoved: (_) async {},
      onOpenControllers: () {},
      onRenameOwner: () {},
      onChangeNetwork: () {},
      verifyOwnerDomain: failVerify
          ? (_) async => throw const FormatException('invalid signature')
          : directory.verify,
      onRealignOwnerDomain: failSave
          ? (_) async => throw StateError('disk unavailable')
          : directory.realignOwnerDomain,
    )));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'settings validates the offered directory and confirmation accepts exactly it',
      (tester) async {
    await directory.open(hostId: 'a', bootstrap: () async => target(2));
    await showSettings(tester);
    final action = find.byKey(const Key('realign-owner-domain'));
    expect(action, findsOneWidget);
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await expectLater(verifier.verify(target(1)),
        throwsA(isA<OwnerDomainGenerationRollback>()));
    await tester.tap(action);
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('confirm-realign-owner-domain-action')));
    await tester.pumpAndSettle();
    expect(action, findsNothing);
    await verifier.verify(target(1));
    expect(
        (await directory.load(ownerDomainIdFixture))
            .ownerDomainDescriptor
            .ownerDomainGeneration,
        1);
  });

  testWidgets('an unrelated validation failure never offers a trust reset',
      (tester) async {
    await showSettings(tester, failVerify: true);
    expect(find.byKey(const Key('realign-owner-domain')), findsNothing);
  });

  testWidgets('a failed reset stays visible and reports failure',
      (tester) async {
    await directory.open(hostId: 'a', bootstrap: () async => target(2));
    await showSettings(tester, failSave: true);
    final action = find.byKey(const Key('realign-owner-domain'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('confirm-realign-owner-domain-action')));
    await tester.pumpAndSettle();
    expect(action, findsOneWidget);
    expect(find.text('暂时无法接受主机当前状态，请重新打开设置后再试。'), findsOneWidget);
    await expectLater(verifier.verify(target(1)),
        throwsA(isA<OwnerDomainGenerationRollback>()));
  });
}
