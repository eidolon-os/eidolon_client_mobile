/// Asking the Authority what this Body's configuration is right now.
///
/// One call, `configuration:pull`, and it answers two things a phone cannot
/// know on its own: whether its Claim still stands, and which channel — if any
/// — it may currently talk through. Both are the Authority's to say. A device
/// that inferred either from a local record would keep speaking after a
/// revocation and keep silent after a channel arrived.
///
/// ## Why the Claim state comes back at all
///
/// Because this is the edge where a device learns it was revoked. Nothing else
/// tells it: revocation happens at the Host, between the Owner and the
/// Authority, and the phone finds out the next time it asks. So `revoked` here
/// is not an error — it is the answer, and the caller's job is to stop being a
/// Body rather than to retry.
///
/// ## The signing document is a third hand-written copy
///
/// The Authority builds it in `hub/device_control/application.py` and the
/// firmware builds the same bytes in
/// `eidolon-client-esp32/main/eidolon/hub_onboarding_protocol.cc`; neither is
/// written down in `eidolon_sdk/contracts`. The ordering and escaping here come
/// from the one canonicaliser this app owns, which RFC 8785's own vector pins,
/// so what is unpinned is the member set — and
/// `test/device_control_client_test.dart` states it so a change has to be typed
/// twice. The proper fix is a golden, and it is a contracts change.
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../protocol/canonical_json.dart';
import '../../protocol/livekit_session_binding.dart';
import '../../models/hub_models.dart';
import '../device_setup/device_instance_identity.dart';
import '../../generated/device_foundation_v1.dart';

/// The operation the Authority verifies this device's signature against.
const deviceControlConfigurationOperation = 'device-control.configuration';

/// What the Authority currently says about this Body.
class DeviceConfiguration {
  const DeviceConfiguration({
    required this.claimStands,
    required this.session,
    required this.deviceRef,
    this.manifest,
  });

  /// Whether the Claim is still active.
  ///
  /// False means revoked, which is an answer rather than a failure — and the
  /// one thing a phone must never learn from its own records.
  final bool claimStands;
  final ManifestRefV1? manifest;

  /// The room this device may join, when the Authority delivered one.
  ///
  /// Null with [claimStands] true is the ordinary case while a channel is being
  /// provisioned, and also the case where provisioning refused. Those look the
  /// same on this edge on purpose: the Authority returns no channels either
  /// way, and a client that guessed which one it was would be inventing a
  /// reason.
  final RoomConfig? session;

  /// The `DeviceRef` the Authority holds for this device, as it answered it.
  ///
  /// **Not necessarily the one the request carried.** The Authority finds the
  /// Claim by identity — `device_instance_id` and `owner_domain_id` — and
  /// answers with the ref on the row, so a Body whose stored ref fell behind
  /// its own Claim is corrected here instead of refused. It used to be
  /// refused: the lookup compared the whole five-member tuple, a re-granted
  /// device matched nothing, and every retry carried the same stale ref, so
  /// nothing the device could do on its own ended the 409.
  ///
  /// Carried whole, for the same reason `MobileBodyClaimStore` carries it
  /// whole: it is what the next pull, the acknowledgement proof and a Manifest
  /// assertion are stated *over*, and a copy rebuilt from the members this
  /// build happens to know would be a different document at the far end.
  ///
  /// A caller holding a stored ref should write this one back when it differs.
  /// The generations are all that may differ — the identity is checked against
  /// what the request presented before this is handed back, because an answer
  /// about another device is not a correction.
  final Map<String, Object?> deviceRef;
}

/// Raised when the Authority refuses or answers unreadably.
class DeviceControlRefusal implements Exception {
  const DeviceControlRefusal({
    required this.detail,
    required this.status,
    required this.retryable,
    this.invalidResponse = false,
  });

  final bool invalidResponse;
  final String detail;
  final int status;

  /// Whether asking again can change the answer on its own.
  final bool retryable;

  @override
  String toString() => 'DeviceControlRefusal($status): $detail';
}

/// The device-facing half of Device Control.
class DeviceControlClient {
  DeviceControlClient({
    required this.authority,
    required http.Client transport,
    this.timeout = const Duration(seconds: 20),
    Random? random,
    String Function()? newNonce,
  })  : _transport = transport,
        _random = random ?? Random.secure(),
        _newNonce = newNonce;

  /// The `device-control` authority endpoint from the signed directory.
  final Uri authority;

  final http.Client _transport;
  final Duration timeout;
  final Random _random;

  /// Where the nonce comes from, overridable only so a test can reproduce the
  /// contract's own vector.
  ///
  /// The same shape `MobileBodyEnrollmentSession` uses for its command ids, and
  /// for the same reason: `DF-DEVICE-CONTROL-CONFIGURATION-PROOF-001` fixes a
  /// nonce, and a document that can never carry the vector's nonce can never be
  /// compared to the vector's bytes. Seeding [random] would not do it — the
  /// vector's value is not a 32-byte draw.
  final String Function()? _newNonce;

  void close() => _transport.close();

  static const _path = '/api/device-control/v1/configuration:pull';

  /// Ask what this Body's configuration is, proving it is that Body.
  ///
  /// The signed document is `DF-DEVICE-CONTROL-CONFIGURATION-PROOF-001`. It was
  /// the third hand-written spelling of a rule with no vector — a Python dict in
  /// the Authority, a concatenated string in the firmware, and the map below —
  /// and a device that spelled it differently would hold an active Claim and
  /// never be given a room, which this product cannot tell apart from waiting.
  ///
  /// [sign] receives the canonical bytes and returns ES256 `r || s` base64url —
  /// the operational key's signature, made on the platform where that key
  /// lives. Passed as a function rather than a key for the obvious reason: the
  /// key never comes here.
  Future<DeviceConfiguration> pullConfiguration({
    required Map<String, Object?> deviceRef,
    required String operationalPublicKey,
    required Future<String> Function(String canonicalDocument) sign,
  }) async {
    final nonce = _nonce();
    final signature = await sign(
      canonicalJsonEncode(<String, Object?>{
        'device_ref': deviceRef,
        'nonce': nonce,
        'operation_type': deviceControlConfigurationOperation,
      }),
    );
    final response = await _transport
        .post(
          authority.resolveUri(Uri.parse(_path)),
          headers: const {
            'accept': 'application/json',
            'content-type': 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'device_ref': deviceRef,
            'nonce': nonce,
            'public_key_spki': operationalPublicKey,
            'device_signature': signature,
          }),
        )
        .timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DeviceControlRefusal(
        detail: _detailOf(response),
        status: response.statusCode,
        // 409 is a stale generation and 403 is a rejected proof: both are
        // answers about this device, and asking again with the same facts
        // produces the same answer. Only a server-side fault is worth a retry.
        retryable: response.statusCode >= 500,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw DeviceControlRefusal(
        detail: 'Device Control answered with a body that is not JSON',
        status: response.statusCode,
        invalidResponse: true,
        retryable: false,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw DeviceControlRefusal(
        detail: 'Device Control answered with something that is not an object',
        status: response.statusCode,
        invalidResponse: true,
        retryable: false,
      );
    }
    if (decoded['operation'] != deviceControlConfigurationOperation) {
      // An answer to another question is not an answer to this one. The nonce
      // does not cover it: `DF-DEVICE-CONTROL-CONFIGURATION-WRONG-OPERATION`
      // carries this ask's own nonce on a `manifest-assert` reply, so a client
      // checking only the echo would read a different operation's lifecycle
      // and channels as its own.
      throw DeviceControlRefusal(
        detail: 'Device Control answered a different operation: '
            '${decoded['operation']}',
        status: response.statusCode,
        invalidResponse: true,
        retryable: false,
      );
    }
    if (decoded['nonce'] != nonce) {
      // The nonce comes back so a device can tell this answer from a replayed
      // one. Checked rather than trusted: an answer about an older ask could
      // report a Claim that has since been revoked.
      throw DeviceControlRefusal(
        detail: 'Device Control answered a different request',
        status: response.statusCode,
        invalidResponse: true,
        retryable: false,
      );
    }

    // The ref the Authority holds. Read after the two checks above and not
    // before: an answer to another operation or another ask is not evidence
    // about this device's generations either, and a re-pin taken from one
    // would write a stale — or someone else's — ref over the Claim this phone
    // holds.
    final answered = decoded['device_ref'];
    if (answered is! Map ||
        answered['owner_domain_generation'] is! int ||
        answered['claim_generation'] is! int ||
        answered['trust_epoch'] is! int) {
      // The generations are what a stored Claim is kept for, and
      // `MobileBodyClaimRecord.fromJson` discards a record whose
      // `claim_generation` or `trust_epoch` will not read as an integer —
      // silently, on the next read. So an answer that cannot supply all three
      // is refused rather than handed on to be stored: a phone that saved one
      // would come back believing it had never enrolled.
      throw DeviceControlRefusal(
        detail: 'Device Control answered without a DeviceRef this build can '
            'read',
        status: response.statusCode,
        invalidResponse: true,
        retryable: false,
      );
    }
    if (answered['device_instance_id'] != deviceRef['device_instance_id'] ||
        answered['owner_domain_id'] != deviceRef['owner_domain_id']) {
      // Only the generations may move. Identity is what the Claim was found
      // by, so an answer naming a different device or a different Owner Domain
      // is not this device's configuration — it is another one's, wearing this
      // ask's nonce. Refused the way any unreadable answer is, because the one
      // thing that must not happen is storing it: this phone cannot sign for
      // that ref, and every later ask would be refused with no way back.
      throw DeviceControlRefusal(
        detail: 'Device Control answered about another device: '
            '${answered['device_instance_id']} in '
            '${answered['owner_domain_id']}',
        status: response.statusCode,
        invalidResponse: true,
        retryable: false,
      );
    }
    final held = Map<String, Object?>.from(answered);

    final manifest = decoded['manifest'] == null
        ? null
        : ManifestRefV1.fromJson(
            Map<String, dynamic>.from(decoded['manifest'] as Map));
    final lifecycle = decoded['lifecycle_state'];
    if (lifecycle != 'approved' && lifecycle != 'revoked') {
      throw DeviceControlRefusal(
        detail: 'Device Control reported a lifecycle state this build does '
            'not know: $lifecycle',
        status: response.statusCode,
        invalidResponse: true,
        retryable: false,
      );
    }
    if (lifecycle == 'revoked') {
      return DeviceConfiguration(
        claimStands: false,
        session: null,
        deviceRef: held,
        manifest: manifest,
      );
    }

    final channels = decoded['channels'];
    if (channels is! List || channels.isEmpty) {
      return DeviceConfiguration(
        claimStands: true,
        session: null,
        deviceRef: held,
        manifest: manifest,
      );
    }
    final channel = channels.first;
    if (channel is! Map<String, dynamic>) {
      throw DeviceControlRefusal(
        detail: 'Device Control delivered a channel this build cannot read',
        status: response.statusCode,
        invalidResponse: true,
        retryable: false,
      );
    }
    final issuedAt = channel['issued_at_ms'];
    final expiresAt = channel['expires_at_ms'];
    if (issuedAt is! int || expiresAt is! int || expiresAt <= issuedAt) {
      // A grant with no life left is not a grant: accepting it spends the
      // reconnect budget on a room that will refuse the token.
      //
      // Judged against the grant's own issue time rather than against this
      // phone's clock. Two reasons, and the second one is a caution rather
      // than a justification:
      //
      // The reason to prefer it: a wall-clock comparison would let a phone
      // with a wrong clock refuse a channel that is perfectly good, which is a
      // worse failure than the one it prevents. It also cannot be applied to
      // a recorded example at all — the vector's accepted channel expires at
      // a fixed instant nine days in the past, as any recorded example's
      // eventually must, so a clock-judging consumer refuses the case the
      // contract calls valid.
      //
      // The caution: **the vector does not pin this rule**, and I briefly
      // credited it with doing so. `DF-DEVICE-CONTROL-CONFIGURATION-RESPONSE-001`
      // says an expired channel must be refused and never says how expiry is
      // judged; its `expires_at_ms: 0` was chosen to match the firmware, which
      // tests `> 0`. So the firmware and this client already disagree — on
      // `expires_at_ms: 1` with a large `issued_at_ms`, it accepts and this
      // refuses — and the contract does not say which is right. Reported to
      // the SDK. Until it answers, this is a choice, not a pinned rule.
      throw DeviceControlRefusal(
        detail: 'Device Control delivered a channel with no life in it',
        status: response.statusCode,
        invalidResponse: true,
        retryable: false,
      );
    }
    final binding = channel['opaque_binding'];
    if (binding is! String || binding.isEmpty) {
      // Says a channel exists and withholds how to reach it, which is worse
      // than saying there is none — an empty binding would otherwise reach
      // `liveKitSessionFromBinding` and be reported as unreadable bytes, when
      // what happened is that the Authority sent none.
      throw DeviceControlRefusal(
        detail:
            'Device Control named a channel and delivered no binding for it',
        status: response.statusCode,
        invalidResponse: true,
        retryable: false,
      );
    }
    return DeviceConfiguration(
      claimStands: true,
      deviceRef: held,
      manifest: manifest,
      session: liveKitSessionFromBinding(
        bindingFormat: channel['binding_format'] as String? ?? '',
        opaqueBinding: binding,
      ),
    );
  }

  /// Standard Device Foundation assertion; the device signs its own document
  /// digest. This neither approves a Claim nor assigns a Companion.
  Future<void> assertManifest({
    required Map<String, Object?> deviceRef,
    required Map<String, Object?> manifest,
    required String operationalPublicKey,
    required Future<String> Function(String canonicalDocument) sign,
  }) async {
    const operation = 'device-control.manifest-assert';
    final nonce = _nonce();
    final signature = await sign(canonicalJsonEncode({
      'device_ref': deviceRef,
      'manifest_digest': manifest['digest'],
      'nonce': nonce,
      'operation_type': operation,
    }));
    final response = await _transport
        .post(
          authority.resolve('/api/device-control/v1/manifest:assert'),
          headers: const {
            'accept': 'application/json',
            'content-type': 'application/json'
          },
          body: jsonEncode({
            'contract': 'eidolon.device-foundation.manifest-assertion',
            'contract_version': '1.0',
            'device_ref': deviceRef,
            'manifest': manifest,
            'nonce': nonce,
            'public_key_spki': operationalPublicKeySpki(operationalPublicKey),
            'device_signature': signature,
          }),
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DeviceControlRefusal(
          detail: _detailOf(response),
          status: response.statusCode,
          retryable: response.statusCode >= 500);
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final expected = {
      for (final k in ['manifest_id', 'revision', 'digest']) k: manifest[k]
    };
    if (decoded is! Map ||
        decoded['contract'] !=
            'eidolon.device-foundation.manifest-acceptance' ||
        decoded['contract_version'] != '1.0' ||
        decoded['nonce'] != nonce ||
        !['accepted', 'unchanged'].contains(decoded['outcome']) ||
        canonicalJsonEncode(decoded['device_ref']) !=
            canonicalJsonEncode(deviceRef) ||
        canonicalJsonEncode(decoded['accepted']) !=
            canonicalJsonEncode(expected)) {
      throw DeviceControlRefusal(
          detail: '主机未确认本次设备声明',
          status: response.statusCode,
          retryable: false,
          invalidResponse: true);
    }
  }

  /// A fresh nonce, in the shape the contract accepts.
  ///
  /// 32 random bytes as unpadded base64url — 43 characters, inside the
  /// contract's 16..128, and drawn from a secure source because its whole job
  /// is to make one answer belong to one ask.
  String _nonce() {
    final override = _newNonce;
    if (override != null) return override();
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _detailOf(http.Response response) {
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is Map<String, dynamic> && body['detail'] is String) {
        return body['detail'] as String;
      }
    } on FormatException {
      // Fall through to the status. A refusal this app cannot read is still a
      // refusal, and saying so beats quoting bytes at a person.
    }
    return 'Device Control refused with HTTP ${response.statusCode}';
  }
}
