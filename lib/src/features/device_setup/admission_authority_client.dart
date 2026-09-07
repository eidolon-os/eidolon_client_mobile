/// The device half of Admission, spoken directly to the Authority.
///
/// This is not the Controller surface. Everything else this app does with
/// Admission — listing what is waiting, approving it, issuing a voucher — goes
/// through the Host's Local API, because those are things an Owner does. These
/// four calls are things a *device* does about itself, and the contract puts
/// them at the Authority, reached over the Owner Domain's own trust anchor
/// rather than the Host's TLS pin.
///
/// The phone therefore speaks both roles, on two transports, and that is the
/// design rather than an accident: the Controller session says who the Owner is,
/// and the operational key says which Body this is. Collapsing them onto one
/// credential is what `docs/设备与Body/纯软件Body准入身份裁决.md` refused, because
/// then a revoked Body and a revoked Controller would be the same revocation.
///
/// Requests are validated against the generated bindings before they are sent.
/// The Authority answers a wrong field set with a 422 that names the difference,
/// which is a round trip and a log line to learn something this side already
/// knows — and on a phone in someone's hand, learns nowhere.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../generated/device_foundation_v1.dart';
import 'admission_evidence.dart';

/// A refusal from the Admission Authority, as it stated it.
///
/// Carries the Authority's own vocabulary rather than an HTTP status, because
/// the codes are what the recovery hangs on: `REVISION_CONFLICT` is a re-read,
/// `HANDOFF_PROOF_INVALID` is a re-proposal, and `DECISION_REQUIRED` is a
/// person. A screen that only knows "it failed" cannot tell those apart, which
/// is how a retry button ends up in front of an approval nobody has given.
class AdmissionRefusal implements Exception {
  const AdmissionRefusal({
    required this.code,
    required this.category,
    required this.retryable,
    required this.detail,
    required this.status,
    this.incidentId,
  });

  final String code;
  final String category;
  final bool retryable;
  final String detail;
  final int status;
  final String? incidentId;

  /// Whether waiting or retrying can change this outcome on its own.
  bool get advancesOnItsOwn => retryable;

  @override
  String toString() => 'AdmissionRefusal($code, $category): $detail';
}

/// The Admission Authority's device-facing commands.
class AdmissionAuthorityClient {
  const AdmissionAuthorityClient({
    required this.authority,
    required http.Client transport,
    this.timeout = const Duration(seconds: 20),
  }) : _transport = transport;

  /// The `admission` authority endpoint from the Owner Domain descriptor.
  ///
  /// Taken from the signed directory, never from a Host-supplied address: the
  /// descriptor is what says where this Owner Domain's Authority lives, and a
  /// reachable endpoint is not an authority.
  final Uri authority;

  final http.Client _transport;
  final Duration timeout;

  static const _basePath = '/api/admission/v1';

  /// Propose this device for admission.
  ///
  /// [commandId] is the idempotency key over this proposal. A retry after a
  /// lost reply must reuse it — that is what makes the retry a resumption
  /// rather than a second proposal that orphans the first.
  Future<CreateEnrollmentResultV1> createEnrollment({
    required String commandId,
    required String correlationId,
    required String deviceInstanceCandidateId,
    required String requestedOwnerDomainId,
    required Map<String, Object?> hardwareIdentityEvidence,
    required Map<String, Object?> commissioningProof,
    required Map<String, Object?> manifest,
    required String handoffPublicKey,
    required String operationalPublicKey,
  }) async {
    final command = <String, Object?>{
      'profile_id': admissionProfileId,
      'device_instance_candidate_id': deviceInstanceCandidateId,
      'requested_owner_domain_id': requestedOwnerDomainId,
      'hardware_identity_evidence': hardwareIdentityEvidence,
      'commissioning_proof': commissioningProof,
      'manifest': manifest,
      'handoff_key': <String, Object?>{
        'scheme': 'DHKEM-P256-HKDF-SHA256',
        'public_key': handoffPublicKey,
      },
      'operational_key': <String, Object?>{
        'scheme': 'ES256-P256',
        'public_key': operationalPublicKey,
      },
    };
    // Refuse locally what the Authority would refuse remotely.
    CreateEnrollmentV1.fromJson(Map<String, dynamic>.from(command));

    final body = await _post(
      Uri.parse('$_basePath/enrollments'),
      commandId: commandId,
      correlationId: correlationId,
      command: command,
    );
    return CreateEnrollmentResultV1.fromJson(body);
  }

  /// Collect the sealed ClaimGrant for an approved proposal.
  Future<CollectClaimGrantResultV1> collectClaimGrant({
    required String commandId,
    required String correlationId,
    required String enrollmentId,
    required int proposalRevision,
    required String collectionChallenge,
    required String handoffKeyProof,
  }) async {
    final command = <String, Object?>{
      'enrollment_id': enrollmentId,
      'proposal_revision': proposalRevision,
      'collection_challenge': collectionChallenge,
      'handoff_key_proof': handoffKeyProof,
    };
    CollectClaimGrantV1.fromJson(Map<String, dynamic>.from(command));

    final body = await _post(
      Uri.parse(
        '$_basePath/enrollments/${_segment(enrollmentId)}/claim-grants:collect',
      ),
      commandId: commandId,
      correlationId: correlationId,
      command: command,
    );
    return CollectClaimGrantResultV1.fromJson(body);
  }

  /// Tell the Authority the Grant was opened and stored.
  ///
  /// [storedClaimGeneration] and [storedTrustEpoch] are read back out of the
  /// Grant this device actually opened, not out of what it expected. The
  /// Authority refuses a mismatch, which is the fence that keeps a device from
  /// acknowledging a generation it never held.
  Future<AckClaimGrantResultV1> ackClaimGrant({
    required String commandId,
    required String correlationId,
    required String enrollmentId,
    required String grantId,
    required String operationalKeyProof,
    required int storedClaimGeneration,
    required int storedTrustEpoch,
  }) async {
    final command = <String, Object?>{
      'enrollment_id': enrollmentId,
      'grant_id': grantId,
      'operational_key_proof': operationalKeyProof,
      'stored_claim_generation': storedClaimGeneration,
      'stored_trust_epoch': storedTrustEpoch,
    };
    AckClaimGrantV1.fromJson(Map<String, dynamic>.from(command));

    final body = await _post(
      Uri.parse(
        '$_basePath/enrollments/${_segment(enrollmentId)}'
        '/claim-grants/${_segment(grantId)}:ack',
      ),
      commandId: commandId,
      correlationId: correlationId,
      command: command,
    );
    return AckClaimGrantResultV1.fromJson(body);
  }

  /// Abandon a proposal this device can no longer finish.
  ///
  /// The forward path when the handoff key is gone — a restart, or a second
  /// proposal — because the Grant it would be sealed to can never be opened.
  /// Without this the enrollment sits approved forever and the screen has
  /// nothing true to offer but waiting.
  Future<CancelEnrollmentResultV1> cancelEnrollment({
    required String commandId,
    required String correlationId,
    required String enrollmentId,
    required String reason,
  }) async {
    final command = <String, Object?>{
      'enrollment_id': enrollmentId,
      'reason': reason,
    };
    CancelEnrollmentV1.fromJson(Map<String, dynamic>.from(command));

    final body = await _post(
      Uri.parse('$_basePath/enrollments/${_segment(enrollmentId)}:cancel'),
      commandId: commandId,
      correlationId: correlationId,
      command: command,
    );
    return CancelEnrollmentResultV1.fromJson(body);
  }

  Future<Map<String, dynamic>> _post(
    Uri path, {
    required String commandId,
    required String correlationId,
    required Map<String, Object?> command,
  }) async {
    if (commandId.trim().isEmpty || correlationId.trim().isEmpty) {
      throw const FormatException(
        'Admission commands need a command id and a correlation id: '
        'they are what makes a retry a resumption',
      );
    }
    final response = await _transport
        .post(
          authority.resolveUri(path),
          headers: const {
            'accept': 'application/json',
            'content-type': 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'command_id': commandId,
            'correlation_id': correlationId,
            ...command,
          }),
        )
        .timeout(timeout);

    final decoded = _decode(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }
    throw _refusal(decoded, response.statusCode);
  }

  Map<String, dynamic> _decode(http.Response response) {
    final Object? value;
    try {
      value = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw AdmissionRefusal(
        code: 'INVALID_AUTHORITY_RESPONSE',
        category: 'invalid',
        // Not retryable: a body that is not JSON is not a busy Authority, and
        // retrying it is how a client spins on a misconfigured endpoint.
        retryable: false,
        detail: 'Admission answered HTTP ${response.statusCode} with a body '
            'that is not JSON',
        status: response.statusCode,
      );
    }
    if (value is! Map<String, dynamic>) {
      throw AdmissionRefusal(
        code: 'INVALID_AUTHORITY_RESPONSE',
        category: 'invalid',
        retryable: false,
        detail: 'Admission answered with a ${value.runtimeType}, not an object',
        status: response.statusCode,
      );
    }
    return value;
  }

  AdmissionRefusal _refusal(Map<String, dynamic> body, int status) {
    try {
      final problem = DeviceProblemV1.fromJson(body);
      return AdmissionRefusal(
        code: problem.json['code'] as String,
        category: problem.json['category'] as String,
        retryable: problem.json['retryable'] as bool,
        detail: (problem.json['detail'] as String?) ?? '',
        status: status,
        incidentId: problem.json['incident_id'] as String?,
      );
    } on FormatException {
      // A refusal this app cannot read is still a refusal, and saying so beats
      // reporting the transport's status code as if it were the Authority's
      // answer.
      return AdmissionRefusal(
        code: 'UNREADABLE_PROBLEM',
        category: 'invalid',
        retryable: false,
        detail: 'Admission refused with a problem document this version '
            'does not understand',
        status: status,
      );
    }
  }

  /// Path segments are identifiers, and are encoded as such.
  ///
  /// `:collect` and `:ack` are literal suffixes in the route, so the identifier
  /// before them must not be able to introduce one of its own.
  static String _segment(String value) {
    if (value.trim().isEmpty) {
      throw const FormatException('Admission identifier cannot be empty');
    }
    return Uri.encodeComponent(value);
  }
}
