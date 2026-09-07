import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_claim_store.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/admission_fixtures.dart';
import 'support/phone_identity_fixtures.dart';

/// What this phone remembers about being a Body, and what it refuses to.
///
/// The record is a hint about which Claim to ask about, never a statement that
/// the phone is claimed — a Claim can be revoked while the app is closed. So
/// these assertions are mostly about the cases where the honest answer is "I do
/// not know": an unreadable record, and a record left behind by an installation
/// that no longer exists.
void main() {
  Map<String, Object?> grantRef() => Map<String, Object?>.from(
        canonicalContractValue('DF-ADMISSION-CLAIM-GRANT-VALID')['device_ref']!
            as Map,
      );

  MobileBodyClaimRecord record({String? instanceId}) => MobileBodyClaimRecord(
        deviceRef: grantRef(),
        grantId: 'grant_01',
        ownerDomainId: grantRef()['owner_domain_id']! as String,
        deviceInstanceId: instanceId ?? phoneDeviceInstanceId,
        acknowledgedAt: DateTime.utc(2026, 9, 6, 12),
      );

  test('a saved Claim survives a round trip whole', () async {
    final preferences = InMemoryAppPreferences();
    final store = PlatformMobileBodyClaimStore(preferences: preferences);

    await store.save(record());
    final loaded = await store.load();

    // The ref is compared as a whole document. Asserting member by member
    // would pass a record that had quietly lost one.
    expect(loaded!.deviceRef, grantRef());
    expect(loaded.grantId, 'grant_01');
    expect(loaded.acknowledgedAt, DateTime.utc(2026, 9, 6, 12));
  });

  test('a Claim from a previous installation is not returned', () async {
    // Uninstalling destroys the Keystore key, so a reinstall derives a
    // different instance id and the stored record is about a device that no
    // longer exists on this phone. Returning it would make the phone present
    // an identity it cannot sign for, and the only symptom would be an
    // Authority refusing a proof for reasons the screen could not explain.
    final store = PlatformMobileBodyClaimStore(
      preferences: InMemoryAppPreferences(),
    );
    await store.save(record(instanceId: 'device-instance-${'f' * 64}'));

    expect(await store.load(), isNotNull);
    expect(await store.loadFor(phoneOperationalPublicKey), isNull);
  });

  test('a Claim for this key is returned', () async {
    final store = PlatformMobileBodyClaimStore(
      preferences: InMemoryAppPreferences(),
    );
    await store.save(record());

    final loaded = await store.loadFor(phoneOperationalPublicKey);

    // The id is derived from the key rather than compared against a stored
    // spelling of it — the derivation is the same one the Authority applies.
    expect(loaded!.deviceInstanceId, phoneDeviceInstanceId);
  });

  test('a key this app cannot read matches nothing', () async {
    final store = PlatformMobileBodyClaimStore(
      preferences: InMemoryAppPreferences(),
    );
    await store.save(record());

    // A raw uncompressed point is a real mistake with a well-formed result:
    // it derives an id no Authority has a record of. It must not match here.
    expect(await store.loadFor('p256-spki:not-base64url!!'), isNull);
  });

  test('an unreadable record reads as no record', () async {
    // Refusing to start because of a local file would be the worst of both:
    // the Authority is asked either way.
    final preferences = InMemoryAppPreferences();
    await preferences.writeString(
      'eidolon.mobile-body-claim.v1',
      'not json at all',
    );

    expect(
      await PlatformMobileBodyClaimStore(preferences: preferences).load(),
      isNull,
    );
  });

  test('a record without a generation is discarded, not half-read', () async {
    // The two members a stored Claim is only useful for. A record missing them
    // would throw at some later call site with no way to explain itself.
    final preferences = InMemoryAppPreferences();
    await preferences.writeString(
      'eidolon.mobile-body-claim.v1',
      jsonEncode(<String, Object?>{
        'device_ref': <String, Object?>{'device_instance_id': 'x'},
        'grant_id': 'grant_01',
        'owner_domain_id': 'owner-domain_01',
        'device_instance_id': phoneDeviceInstanceId,
        'acknowledged_at': '2026-09-06T12:00:00Z',
      }),
    );

    expect(
      await PlatformMobileBodyClaimStore(preferences: preferences).load(),
      isNull,
    );
  });

  test('clearing forgets the Claim on this phone', () async {
    // What a phone does after being told its Claim was revoked. Nothing is
    // asked of the Authority.
    final store = PlatformMobileBodyClaimStore(
      preferences: InMemoryAppPreferences(),
    );
    await store.save(record());

    await store.clear();

    expect(await store.load(), isNull);
  });

  test('the in-memory store answers the same questions', () async {
    // Used by every test that exercises the enrollment chain, so it has to
    // agree with the real one about the reinstall case in particular.
    final store = InMemoryMobileBodyClaimStore();
    await store.save(record(instanceId: 'device-instance-${'f' * 64}'));

    expect(await store.load(), isNotNull);
    expect(await store.loadFor(phoneOperationalPublicKey), isNull);

    await store.save(record());
    expect(await store.loadFor(phoneOperationalPublicKey), isNotNull);

    await store.clear();
    expect(await store.load(), isNull);
  });
}
