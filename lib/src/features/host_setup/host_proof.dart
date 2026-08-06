import '../setup/setup_trust.dart';

class HostProof {
  const HostProof({
    required this.contractVersion,
    required this.purpose,
    required this.hostId,
    required this.challenge,
    required this.signature,
  });

  static const requiredPurpose = 'eidolon-local-api-host-proof-v1';
  static const _requiredKeys = <String>{
    'contract_version',
    'purpose',
    'host_id',
    'challenge',
    'signature',
  };

  factory HostProof.fromJson(Map<String, dynamic> json) {
    if (json.length != _requiredKeys.length ||
        !json.keys.every(_requiredKeys.contains)) {
      throw const SetupTrustException(
        'Local API Host proof 字段与 v1 契约不一致',
      );
    }
    final contractVersion = _requiredString(json, 'contract_version');
    final purpose = _requiredString(json, 'purpose');
    final hostId = _requiredString(json, 'host_id');
    final challenge = _requiredString(json, 'challenge');
    final signature = _requiredString(json, 'signature');
    if (contractVersion != '1' ||
        purpose != requiredPurpose ||
        !RegExp(r'^ehost-[0-9a-f]{20}$').hasMatch(hostId) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(challenge) ||
        !RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(signature)) {
      throw const SetupTrustException('Local API Host proof 内容无效');
    }
    return HostProof(
      contractVersion: contractVersion,
      purpose: purpose,
      hostId: hostId,
      challenge: challenge,
      signature: signature,
    );
  }

  final String contractVersion;
  final String purpose;
  final String hostId;
  final String challenge;
  final String signature;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw SetupTrustException('Local API Host proof 缺少或包含无效字段：$key');
  }
  return value;
}
