import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_device_contexts.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_claim_store.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'package:eidolon_client_mobile/src/platform/platform_bridge.dart';
import 'support/phone_identity_fixtures.dart';

MobileBodyClaimRecord record(String owner, {bool pending = false}) =>
    MobileBodyClaimRecord(
        deviceRef: {
          'device_instance_id': phoneDeviceInstanceId,
          'owner_domain_id': owner,
          'owner_domain_generation': 1,
          'claim_generation': 2,
          'trust_epoch': 1
        },
        grantId: 'grant-original',
        ownerDomainId: owner,
        deviceInstanceId: phoneDeviceInstanceId,
        acknowledgedAt: DateTime.utc(2026, 9, 8),
        ackPending: pending,
        ackCommandId: pending ? 'ack-original' : null,
        ackProof: pending ? 'original-proof' : null);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('migration preserves legacy identity and pending ACK only for its Owner',
      () async {
    final prefs = InMemoryAppPreferences();
    final old = PlatformMobileBodyClaimStore(preferences: prefs);
    await old.save(record('owner-a', pending: true));
    final platform = FakePhonePlatform();
    MobileDeviceContexts runtime() =>
        MobileDeviceContexts(preferences: prefs, platform: platform);
    // Start on a different Host: it must not acquire or replace the old key.
    final b = await runtime().open('owner-b');
    expect(b.platform.deviceScope, 'owner-b');
    expect(await b.claims.load(), isNull);
    final a = await runtime().open('owner-a');
    expect(identical(a.platform, platform), true);
    expect((await a.claims.load())!.toJson(),
        record('owner-a', pending: true).toJson());
    expect(await old.load(), isNull);
    await b.claims.save(record('owner-b'));
    expect((await a.claims.load())!.ackPending, true);
    await a.claims.clear();
    expect(await (await runtime().open('owner-a')).claims.load(), isNull,
        reason: 'revoked or cleared claims must never be reimported');
    expect(
        (await (await runtime().open('owner-b')).claims.load())!.ownerDomainId,
        'owner-b');
  });

  test(
      'A B A and restart keep immutable Device scopes without a global selected key',
      () async {
    final prefs = InMemoryAppPreferences();
    final platform = FakePhonePlatform();
    final contexts =
        MobileDeviceContexts(preferences: prefs, platform: platform);
    final a = await contexts.open('a');
    final b = await contexts.open('b');
    await Future.wait([a.claims.save(record('a')), b.claims.save(record('b'))]);
    final restarted =
        MobileDeviceContexts(preferences: prefs, platform: platform);
    final a2 = await restarted.open('a');
    final b2 = await restarted.open('b');
    expect(a2.platform, same(platform));
    expect(b2.platform.deviceScope, b.platform.deviceScope);
    expect((await a2.claims.load())!.ownerDomainId, 'a');
    expect((await b2.claims.load())!.ownerDomainId, 'b');
    expect(() => b.claims.save(record('a')), throwsFormatException);
  });

  test(
      'every device operation carries its bound scope while Controller methods stay separate',
      () async {
    const channel = MethodChannel('live.eidolon.mobile/platform');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getDeviceIdentity':
          return {
            'installId': phoneInstallId,
            'operationalPublicKey': phoneOperationalPublicKey,
            'fingerprint': phoneFingerprint
          };
        case 'issueHandoffKey':
          return {
            'handle': 'h',
            'publicKey': phoneOperationalPublicKey,
            'keyId': 'sha256:key'
          };
        case 'openClaimGrant':
          return base64Url.encode([1]);
        case 'holdsHandoffKey':
        case 'discardHandoffKey':
          return true;
        default:
          return 'signature';
      }
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final a = const PlatformBridge().forDevice('a');
    final b = const PlatformBridge().forDevice('b');
    await a.getDeviceIdentity();
    await b.issueHandoffKey();
    await a.signDeviceCanonicalDocument('{}');
    await b.openClaimGrant(
        handle: 'h', encapsulatedKey: 'k', aad: '{}', ciphertext: 'c');
    await a.signHandoffCanonicalDocument(handle: 'h', document: '{}');
    await b.holdsHandoffKey();
    await a.discardHandoffKey();
    expect(calls.map((c) => (c.arguments as Map)['deviceScope']),
        ['a', 'b', 'a', 'b', 'a', 'b', 'a']);
  });
}
