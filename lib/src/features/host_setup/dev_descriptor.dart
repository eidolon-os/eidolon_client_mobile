import 'dart:collection';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'host_models.dart';

/// A validation failure at the out-of-band trust boundary.
///
/// Messages intentionally never include the commissioning secret or the raw
/// descriptor. The secret remains in memory for the later commissioning
/// transport and must not be written to logs or application preferences.
class SetupTrustException implements Exception {
  const SetupTrustException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DevelopmentCommissioningDescriptor {
  const DevelopmentCommissioningDescriptor._({
    required this.contractVersion,
    required this.hostId,
    required this.hostPublicKey,
    required this.hostPublicKeyFingerprint,
    required this.bleServiceUuid,
    required this.commissioningId,
    required this.commissioningSecret,
    required this.issuedAt,
    required this.expiresAt,
  });

  static const _requiredKeys = <String>{
    'contract_version',
    'host_id',
    'host_public_key',
    'host_public_key_fingerprint',
    'ble_service_uuid',
    'mode',
    'commissioning_id',
    'commissioning_secret',
    'issued_at',
    'expires_at',
    'signature',
  };

  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  /// Parses and verifies the descriptor emitted by
  /// `eidolon-bootstrapctl dev issue`.
  ///
  /// The signature format mirrors Admin's canonical JSON exactly: recursively
  /// sorted object keys, no whitespace, UTF-8 encoding, and the `signature`
  /// member excluded from the signed payload.
  static Future<DevelopmentCommissioningDescriptor> parseAndVerify(
    String input, {
    DateTime Function()? clock,
  }) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(input.trim());
    } on FormatException {
      throw const SetupTrustException('Dev Descriptor 不是有效的 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const SetupTrustException('Dev Descriptor 必须是 JSON object');
    }
    if (decoded.length != _requiredKeys.length ||
        !decoded.keys.every(_requiredKeys.contains)) {
      throw const SetupTrustException('Dev Descriptor 字段与 v1 契约不一致');
    }

    final contractVersion = _requiredString(decoded, 'contract_version');
    if (contractVersion != '1') {
      throw SetupTrustException(
        '不支持的 Dev Descriptor 版本：$contractVersion',
      );
    }
    if (_requiredString(decoded, 'mode') != 'development') {
      throw const SetupTrustException('Dev Descriptor 不是 development 模式');
    }

    final hostId = _requiredString(decoded, 'host_id');
    if (!RegExp(r'^ehost-[0-9a-f]{20}$').hasMatch(hostId)) {
      throw const SetupTrustException('Dev Descriptor 的 Host ID 无效');
    }
    final bleServiceUuid = _requiredString(decoded, 'ble_service_uuid');
    final commissioningId = _requiredString(decoded, 'commissioning_id');
    if (!_uuidPattern.hasMatch(bleServiceUuid) ||
        !_uuidPattern.hasMatch(commissioningId)) {
      throw const SetupTrustException('Dev Descriptor 包含无效 UUID');
    }

    final commissioningSecret =
        _requiredString(decoded, 'commissioning_secret');
    if (commissioningSecret.length < 32) {
      throw const SetupTrustException('Dev Descriptor 的临时凭据无效');
    }
    final issuedAt = _requiredTimestamp(decoded, 'issued_at');
    final expiresAt = _requiredTimestamp(decoded, 'expires_at');
    if (!expiresAt.isAfter(issuedAt)) {
      throw const SetupTrustException('Dev Descriptor 的有效期无效');
    }

    final hostPublicKey = _requiredString(decoded, 'host_public_key');
    final signatureValue = _requiredString(decoded, 'signature');
    final List<int> publicKeyBytes;
    final List<int> signatureBytes;
    try {
      publicKeyBytes = _decodeBase64Url(hostPublicKey);
      signatureBytes = _decodeBase64Url(signatureValue);
    } on FormatException {
      throw const SetupTrustException('Dev Descriptor 的签名材料编码无效');
    }
    if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
      throw const SetupTrustException('Dev Descriptor 的签名材料长度无效');
    }

    final digest = await Sha256().hash(publicKeyBytes);
    final derivedHostId = 'ehost-${_hex(digest.bytes).substring(0, 20)}';
    final derivedFingerprint = 'sha256:${_encodeBase64Url(digest.bytes)}';
    final hostPublicKeyFingerprint =
        _requiredString(decoded, 'host_public_key_fingerprint');
    if (hostId != derivedHostId ||
        hostPublicKeyFingerprint != derivedFingerprint) {
      throw const SetupTrustException(
        'Dev Descriptor 的 Host 身份与公钥不一致',
      );
    }

    final unsigned = Map<String, dynamic>.from(decoded)..remove('signature');
    final message = utf8.encode(jsonEncode(_canonicalize(unsigned)));
    final verified = await Ed25519().verify(
      message,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(
          publicKeyBytes,
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!verified) {
      throw const SetupTrustException('Dev Descriptor 签名验证失败');
    }

    final now = (clock ?? DateTime.now)().toUtc();
    if (!expiresAt.isAfter(now)) {
      throw const SetupTrustException('Dev Descriptor 已过期，请在 Host 上重新签发');
    }

    return DevelopmentCommissioningDescriptor._(
      contractVersion: contractVersion,
      hostId: hostId,
      hostPublicKey: hostPublicKey,
      hostPublicKeyFingerprint: hostPublicKeyFingerprint,
      bleServiceUuid: bleServiceUuid,
      commissioningId: commissioningId,
      commissioningSecret: commissioningSecret,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
    );
  }

  final String contractVersion;
  final String hostId;
  final String hostPublicKey;
  final String hostPublicKeyFingerprint;
  final String bleServiceUuid;
  final String commissioningId;
  final String commissioningSecret;
  final DateTime issuedAt;
  final DateTime expiresAt;

  /// Enforces that the reachable Local API belongs to the identity selected by
  /// the out-of-band descriptor. Discovery or an address is never identity.
  void requireHostMatch(HostOverview host) {
    final local = host.descriptor;
    if (host.mode != BootstrapMode.development ||
        local.contractVersion != contractVersion ||
        local.hostId != hostId ||
        local.hostPublicKey != hostPublicKey ||
        local.hostPublicKeyFingerprint != hostPublicKeyFingerprint ||
        local.bleServiceUuid.toLowerCase() != bleServiceUuid.toLowerCase()) {
      throw const SetupTrustException(
        'Local API 返回的 Host 与已验证 Dev Descriptor 不匹配',
      );
    }
  }

  void requireNotExpired({DateTime Function()? clock}) {
    final now = (clock ?? DateTime.now)().toUtc();
    if (!expiresAt.isAfter(now)) {
      throw const SetupTrustException('Dev Descriptor 已过期，请在 Host 上重新签发');
    }
  }

  /// Verifies a nonce-bound proof returned by the currently reachable Local
  /// API. Metadata matching prevents mistakes; this signature proves that the
  /// connected Bootstrap control plane can use the selected Host private key.
  Future<void> verifyHostProof(
    HostProof proof, {
    required String expectedChallenge,
  }) async {
    if (proof.contractVersion != contractVersion ||
        proof.purpose != HostProof.requiredPurpose ||
        proof.hostId != hostId ||
        proof.challenge != expectedChallenge) {
      throw const SetupTrustException(
        'Local API Host proof 与本次 Setup challenge 不匹配',
      );
    }

    final List<int> publicKeyBytes;
    final List<int> signatureBytes;
    try {
      publicKeyBytes = _decodeBase64Url(hostPublicKey);
      signatureBytes = _decodeBase64Url(proof.signature);
    } on FormatException {
      throw const SetupTrustException('Local API Host proof 编码无效');
    }
    if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
      throw const SetupTrustException('Local API Host proof 长度无效');
    }

    final verified = await Ed25519().verify(
      utf8.encode(jsonEncode(_canonicalize(proof.unsignedJson))),
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(
          publicKeyBytes,
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!verified) {
      throw const SetupTrustException('Local API 未能证明目标 Host 私钥持有权');
    }
  }

  @override
  String toString() => 'DevelopmentCommissioningDescriptor(hostId: $hostId, '
      'commissioningId: $commissioningId, expiresAt: $expiresAt)';
}

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
      throw const SetupTrustException('Local API Host proof 字段与 v1 契约不一致');
    }
    final contractVersion = _requiredString(
      json,
      'contract_version',
      subject: 'Local API Host proof',
    );
    final purpose = _requiredString(
      json,
      'purpose',
      subject: 'Local API Host proof',
    );
    final hostId = _requiredString(
      json,
      'host_id',
      subject: 'Local API Host proof',
    );
    final challenge = _requiredString(
      json,
      'challenge',
      subject: 'Local API Host proof',
    );
    final signature = _requiredString(
      json,
      'signature',
      subject: 'Local API Host proof',
    );
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

  Map<String, dynamic> get unsignedJson => {
        'contract_version': contractVersion,
        'purpose': purpose,
        'host_id': hostId,
        'challenge': challenge,
      };
}

String _requiredString(
  Map<String, dynamic> json,
  String key, {
  String subject = 'Dev Descriptor',
}) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw SetupTrustException('$subject 缺少或包含无效字段：$key');
  }
  return value;
}

DateTime _requiredTimestamp(Map<String, dynamic> json, String key) {
  final parsed = DateTime.tryParse(_requiredString(json, key));
  if (parsed == null) {
    throw SetupTrustException('Dev Descriptor 时间字段无效：$key');
  }
  return parsed.toUtc();
}

dynamic _canonicalize(dynamic value) {
  if (value is Map<String, dynamic>) {
    final sorted = SplayTreeMap<String, dynamic>();
    for (final entry in value.entries) {
      sorted[entry.key] = _canonicalize(entry.value);
    }
    return sorted;
  }
  if (value is List<dynamic>) {
    return value.map(_canonicalize).toList(growable: false);
  }
  return value;
}

List<int> _decodeBase64Url(String value) {
  if (value.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw const FormatException('invalid base64url');
  }
  final padding = (4 - value.length % 4) % 4;
  final suffix = List.filled(padding, '=').join();
  final decoded = base64Url.decode('$value$suffix');
  if (_encodeBase64Url(decoded) != value) {
    throw const FormatException('non-canonical base64url');
  }
  return decoded;
}

String _encodeBase64Url(List<int> value) =>
    base64Url.encode(value).replaceAll('=', '');

String _hex(List<int> value) =>
    value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
