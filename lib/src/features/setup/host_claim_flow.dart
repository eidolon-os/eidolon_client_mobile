import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'host_claim_pake.dart';
import 'setup_models.dart';

/// What this phone already holds about the Host it means to claim, from the
/// endpoint it verified and pinned. The PAKE context is built from this and
/// nothing else; what the Host echoes is only compared against it.
class HostClaimExpectation {
  const HostClaimExpectation({
    required this.hostPublicKey,
    required this.tlsSpkiFingerprint,
    required this.resetEpoch,
    required this.commissioningId,
    required this.transport,
    required this.controllerPublicKey,
  });

  factory HostClaimExpectation.fromEndpoint(
    CommissioningEndpoint endpoint, {
    required String commissioningId,
    required String transport,
    required String controllerPublicKey,
  }) =>
      HostClaimExpectation(
        hostPublicKey: endpoint.hostPublicKey,
        tlsSpkiFingerprint: endpoint.tlsSpkiFingerprint,
        resetEpoch: endpoint.resetEpoch,
        commissioningId: commissioningId,
        transport: transport,
        controllerPublicKey: controllerPublicKey,
      );

  final String hostPublicKey;
  final String tlsSpkiFingerprint;
  final int resetEpoch;
  final String commissioningId;

  /// `ble` or `lan`: the same code proven over the other transport is a
  /// different proof, so one cannot be replayed onto the other.
  final String transport;

  /// Unpadded base64url DER, as the claim will present it.
  final String controllerPublicKey;

  Map<String, Object> contextFor(String handshakeId) => {
        'commissioning_id': commissioningId,
        'controller_public_key_sha256': base64UrlNoPad(
            sha256.convert(base64UrlDecodeNoPad(controllerPublicKey)).bytes),
        'handshake_id': handshakeId,
        'host_public_key': hostPublicKey,
        'reset_epoch': resetEpoch,
        'suite': hostClaimPakeSuite,
        'tls_spki_fingerprint': tlsSpkiFingerprint,
        'transport': transport,
      };
}

typedef HostClaimProver = Future<HostClaimProof> Function(
    HostClaimProofRequest request);

/// Proves [code] to a Host without sending it, and proves the Host back.
///
/// [start] returns null when the Host predates the PAKE (BLE answered
/// `unknown_operation`, the LAN answered 404); this then returns null too and
/// the caller falls back to sending the code the old way. Anything else
/// returned has already passed the Host's own proof, so the caller may
/// believe it — and nothing before that point may be believed.
Future<Map<String, dynamic>?> proveSetupCodeToHost({
  required String code,
  required HostClaimExpectation expected,
  required Future<Map<String, dynamic>?> Function(Map<String, dynamic> payload)
      start,
  required Future<Map<String, dynamic>> Function(Map<String, dynamic> payload)
      confirm,
  HostClaimProver prove = proveHostClaimInBackground,
}) async {
  // One restart for a handshake the Host no longer holds — it keeps one for
  // 30 s, and a phone backgrounded in between is not a reason to fail.
  for (var attempt = 0;; attempt++) {
    final started = await start({
      'suite': hostClaimPakeSuite,
      'commissioning_id': expected.commissioningId,
      'controller_public_key': expected.controllerPublicKey,
    });
    if (started == null) return null;
    final handshakeId = started['handshake_id'];
    final salt = started['salt'];
    final serverPublic = started['B'];
    final echoed = started['context'];
    if (started['suite'] != hostClaimPakeSuite ||
        handshakeId is! String ||
        salt is! String ||
        serverPublic is! String ||
        echoed is! Map) {
      throw const CommissioningRequestException(
          'invalid_response', '主机返回的 Setup 码验证请求无效。');
    }
    final mine = expected.contextFor(handshakeId);
    if (!mapEquals(Map<String, Object?>.from(echoed), mine)) {
      // Before any proof is made, so nothing about the code has left the
      // phone in any form. A Host that names other keys than the ones this
      // phone just verified is not the one it verified.
      throw const CommissioningRequestException(
        'host_identity_mismatch',
        '主机这一步给出的身份和刚才验证过的不一致。已经停止，Setup 码没有以任何形式发出。请重新搜索主机。',
      );
    }
    final HostClaimProof proof;
    try {
      proof = await prove(HostClaimProofRequest(
        code: code,
        identity: expected.commissioningId,
        context: mine,
        salt: salt,
        serverPublic: serverPublic,
      ));
    } on HostClaimPakeRejected {
      throw const CommissioningRequestException(
          'host_not_proven', _notProvenMessage);
    } on FormatException {
      throw const CommissioningRequestException(
          'host_not_proven', _notProvenMessage);
    }
    final Map<String, dynamic> confirmed;
    try {
      confirmed = await confirm({
        'handshake_id': handshakeId,
        'A': proof.clientPublic,
        'client_proof': proof.clientProof,
      });
    } on CommissioningRequestException catch (error) {
      if (error.code == 'pake_handshake_unknown' && attempt == 0) continue;
      rethrow;
    }
    if (!proof.acceptsServerProof(confirmed['server_proof'])) {
      throw const CommissioningRequestException(
          'host_not_proven', _notProvenMessage);
    }
    return confirmed;
  }
}

/// Reaching this means a Host accepted the phone's proof and then could not
/// produce its own — which a Host that knows the code never does.
const _notProvenMessage = '这台主机没能证明它知道这个 Setup 码。已经停止：没有保存它，'
    '也没有把 Wi-Fi 密码发给它。请确认连接的是你自己的主机，然后重新搜索。';
