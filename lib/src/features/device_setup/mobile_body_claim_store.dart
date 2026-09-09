/// What this phone remembers about being a Body, between launches.
///
/// ## A hint, never an authority
///
/// The Authority owns whether a Claim is active. This record says only *which
/// Claim to ask about*: a Claim can be revoked while the app is closed, its
/// generation can move, and the Owner Domain can be reset — none of which this
/// phone would see. So nothing here may be read as "this phone is claimed". It
/// is read as "last time, this phone held this device_ref; go find out what is
/// true now", exactly the way a saved Host's address is a hint about where to
/// look and never a claim that the Host is there.
///
/// Getting that backwards is the expensive direction. A phone that believed a
/// stored Claim would keep presenting a revoked identity and reporting itself
/// as a Body, and the screen would have no way to say otherwise.
///
/// ## Why there are no secrets in it
///
/// A `DeviceRef` is not one. The operational key that makes it usable stays in
/// the Android Keystore and is never written anywhere, and the handoff key that
/// opened the Grant is discarded after ACK. A pending checkpoint retains only
/// the public reference and a proof scoped to that exact ACK. The checkpoint rule this
/// app already follows — no Wi-Fi passwords, no pairing material, no Controller
/// credentials — is intact.
///
/// ## Why it is one slot
///
/// This phone is one Body. Two records for one device instance id is not a case
/// to carry; a second Claim means the first was replaced, and the record should
/// say the current thing rather than accumulate history the Authority already
/// keeps.
library;

import 'dart:convert';

import '../../platform/app_preferences.dart';
import 'device_instance_identity.dart';

/// The Claim this phone last held, as it was handed over.
class MobileBodyClaimRecord {
  const MobileBodyClaimRecord({
    required this.deviceRef,
    required this.grantId,
    required this.ownerDomainId,
    required this.deviceInstanceId,
    required this.acknowledgedAt,
    this.enrollmentId,
    this.ackCommandId,
    this.ackProof,
    this.ackPending = false,
  });

  /// The reference the Authority sealed into the Grant, carried whole.
  ///
  /// Not decomposed into fields and rebuilt: it is what `configuration:pull`
  /// and the acknowledgement proof are stated over, and a reconstruction that
  /// renamed or dropped a member would be a different document.
  final Map<String, Object?> deviceRef;

  final String grantId;
  final String ownerDomainId;

  /// Which operational key this Claim belongs to.
  ///
  /// Stored so it can be compared. Uninstalling the app destroys the Keystore
  /// key, so a reinstall derives a different instance id and this record is
  /// then about a device that no longer exists on this phone. See
  /// [MobileBodyClaimStore.loadFor].
  final String deviceInstanceId;

  final DateTime acknowledgedAt;
  final String? enrollmentId;
  final String? ackCommandId;
  final String? ackProof;
  final bool ackPending;

  MobileBodyClaimRecord acknowledged(DateTime at) => MobileBodyClaimRecord(
        deviceRef: deviceRef,
        grantId: grantId,
        ownerDomainId: ownerDomainId,
        deviceInstanceId: deviceInstanceId,
        acknowledgedAt: at,
        enrollmentId: enrollmentId,
      );

  int get claimGeneration => deviceRef['claim_generation']! as int;

  int get trustEpoch => deviceRef['trust_epoch']! as int;

  factory MobileBodyClaimRecord.fromJson(Map<String, dynamic> value) {
    final deviceRef = value['device_ref'];
    if (deviceRef is! Map) {
      throw const FormatException('Saved Claim has no device ref');
    }
    final ref = Map<String, Object?>.from(deviceRef);
    // The two members a stored Claim is only useful for. Checked here so a
    // truncated record is discarded on read rather than throwing later, at a
    // call site that has no way to explain it.
    if (ref['claim_generation'] is! int || ref['trust_epoch'] is! int) {
      throw const FormatException('Saved Claim has no generation');
    }
    final instanceId = value['device_instance_id'];
    final grantId = value['grant_id'];
    final ownerDomainId = value['owner_domain_id'];
    final acknowledgedAt = value['acknowledged_at'];
    if (instanceId is! String ||
        instanceId.isEmpty ||
        grantId is! String ||
        grantId.isEmpty ||
        ownerDomainId is! String ||
        ownerDomainId.isEmpty ||
        acknowledgedAt is! String) {
      throw const FormatException('Saved Claim is incomplete');
    }
    return MobileBodyClaimRecord(
      deviceRef: ref,
      grantId: grantId,
      ownerDomainId: ownerDomainId,
      deviceInstanceId: instanceId,
      acknowledgedAt: DateTime.parse(acknowledgedAt).toUtc(),
      enrollmentId: value['enrollment_id'] as String?,
      ackCommandId: value['ack_command_id'] as String?,
      ackProof: value['ack_proof'] as String?,
      ackPending: value['ack_pending'] == true,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'device_ref': deviceRef,
        'grant_id': grantId,
        'owner_domain_id': ownerDomainId,
        'device_instance_id': deviceInstanceId,
        'acknowledged_at': acknowledgedAt.toUtc().toIso8601String(),
        if (enrollmentId != null) 'enrollment_id': enrollmentId,
        if (ackCommandId != null) 'ack_command_id': ackCommandId,
        if (ackProof != null) 'ack_proof': ackProof,
        'ack_pending': ackPending,
      };
}

abstract interface class MobileBodyClaimStore {
  /// The saved record, or null when there is none or it cannot be read.
  Future<MobileBodyClaimRecord?> load();

  /// The saved record, but only if it belongs to [operationalPublicKey].
  ///
  /// A record for another key is not a corrupt record and not an error — it is
  /// a Claim that belonged to an installation that no longer exists, because
  /// uninstalling took the Keystore key with it. It is discarded rather than
  /// returned, so nothing downstream has to know the difference between "no
  /// Claim" and "somebody else's Claim".
  Future<MobileBodyClaimRecord?> loadFor(String operationalPublicKey);

  Future<void> save(MobileBodyClaimRecord record);

  /// Forget the Claim on this phone.
  ///
  /// Nothing is asked of the Authority. This is what a phone does after being
  /// told its Claim was revoked, and after a re-enrollment replaces it.
  Future<void> clear();
}

class PlatformMobileBodyClaimStore implements MobileBodyClaimStore {
  PlatformMobileBodyClaimStore({AppPreferences? preferences})
      : _preferences = preferences ?? PlatformAppPreferences();

  static const _key = 'eidolon.mobile-body-claim.v1';

  final AppPreferences _preferences;
  Future<void> _writeQueue = Future<void>.value();

  @override
  Future<MobileBodyClaimRecord?> load() async {
    final raw = await _preferences.readString(_key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return MobileBodyClaimRecord.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      // A record this build cannot read is the same as none: the Authority is
      // asked either way, and refusing to start because of a local file would
      // be the worst of both.
      return null;
    }
  }

  @override
  Future<MobileBodyClaimRecord?> loadFor(String operationalPublicKey) async {
    final record = await load();
    if (record == null) return null;
    final String expected;
    try {
      expected = deriveDeviceInstanceId(operationalPublicKey);
    } on FormatException {
      return null;
    }
    return record.deviceInstanceId == expected ? record : null;
  }

  @override
  Future<void> save(MobileBodyClaimRecord record) {
    final result = _writeQueue.then((_) async {
      await _preferences.writeString(_key, jsonEncode(record.toJson()));
    });
    _writeQueue = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  @override
  Future<void> clear() {
    final result = _writeQueue.then((_) async {
      await _preferences.writeString(_key, '');
    });
    _writeQueue = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }
}

class InMemoryMobileBodyClaimStore implements MobileBodyClaimStore {
  InMemoryMobileBodyClaimStore([this._record]);

  MobileBodyClaimRecord? _record;

  @override
  Future<MobileBodyClaimRecord?> load() async => _record;

  @override
  Future<MobileBodyClaimRecord?> loadFor(String operationalPublicKey) async {
    final record = _record;
    if (record == null) return null;
    try {
      return record.deviceInstanceId ==
              deriveDeviceInstanceId(operationalPublicKey)
          ? record
          : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(MobileBodyClaimRecord record) async {
    _record = record;
  }

  @override
  Future<void> clear() async {
    _record = null;
  }
}
