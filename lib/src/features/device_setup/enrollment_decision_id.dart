import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../generated/device_foundation_v1.dart';
import 'admission_projection.dart';

/// One management intent for one reviewed revision, shared by both surfaces.
String enrollmentDecisionId(
    {required String ownerDomainId,
    required String controllerId,
    required EnrollmentRecoveryProjectionV1 projection}) {
  final digest = sha256.convert(utf8.encode('$ownerDomainId\n$controllerId\n'
      '${projection.proposal.json['enrollment_id']}\n${projection.proposalRevision}'));
  return 'mobile-decision-${base64UrlEncode(digest.bytes).replaceAll('=', '')}';
}
