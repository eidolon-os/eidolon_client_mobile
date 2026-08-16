import 'dart:collection';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'setup_trust.dart';

class NearbyEidolonHost {
  const NearbyEidolonHost({
    required this.address,
    required this.name,
    required this.hostMarker,
    required this.rssi,
  });

  factory NearbyEidolonHost.fromMap(Map<Object?, Object?> value) =>
      NearbyEidolonHost(
        address: _requiredString(value, 'address'),
        name: _requiredString(value, 'name'),
        hostMarker: _requiredString(value, 'hostMarker'),
        rssi: _requiredInt(value, 'rssi'),
      );

  final String address;
  final String name;
  final String hostMarker;
  final int rssi;
}

class WifiNetwork {
  const WifiNetwork({
    required this.ssid,
    required this.signal,
    required this.secured,
  });

  factory WifiNetwork.fromJson(Map<String, dynamic> value) => WifiNetwork(
        ssid: _requiredJsonString(value, 'ssid'),
        signal: _requiredJsonInt(value, 'signal'),
        secured: _requiredJsonBool(value, 'secured'),
      );

  final String ssid;
  final int signal;
  final bool secured;
}

class ControllerIdentity {
  const ControllerIdentity({
    required this.controllerId,
    required this.publicKey,
    required this.fingerprint,
  });

  factory ControllerIdentity.fromMap(Map<Object?, Object?> value) =>
      ControllerIdentity(
        controllerId: _requiredString(value, 'controllerId'),
        publicKey: _requiredString(value, 'publicKey'),
        fingerprint: _requiredString(value, 'fingerprint'),
      );

  final String controllerId;
  final String publicKey;
  final String fingerprint;
}

/// Digits in a Setup code. Mirrors the Host's own rule: eight is what Matter
/// and HomeKit both settled on, short enough to read aloud and safe only
/// because the session it unlocks is one-time, expiring, and dies after a few
/// wrong guesses.
const int setupCodeDigits = 8;
final RegExp setupCodePattern = RegExp('^[0-9]{$setupCodeDigits}\$');

class CommissioningEndpoint {
  const CommissioningEndpoint._({
    required this.hostId,
    required this.hostPublicKey,
    required this.hostPublicKeyFingerprint,
    required this.resetEpoch,
    required this.bleServiceUuid,
    required this.tlsSpkiFingerprint,
    required this.developmentSetup,
    required this.localApiBaseUrls,
  });

  static const defaultServiceUuid = 'f6a147b7-abef-57c3-973f-e3a17c6ef0ab';
  static const _purpose = 'eidolon-ble-commissioning-endpoint-v1';
  static const _keys = <String>{
    'contract_version',
    'purpose',
    'host_public_key',
    'reset_epoch',
    'tls_spki_fingerprint',
    'setup_session',
    'signature',
  };

  /// Keys a Host may send and this App understands, but which a Host that has
  /// not been updated will not send. An App is routinely newer than the Host it
  /// is talking to, so an addition to a signed document has to be additive:
  /// absent means the Host cannot say, not that the document is wrong.
  static const _optionalKeys = <String>{'local_api_base_urls'};
  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  static Future<CommissioningEndpoint> parseAndVerifyDiscovered(
    String input, {
    String expectedServiceUuid = defaultServiceUuid,
  }) =>
      _parseAndVerify(input, expectedServiceUuid: expectedServiceUuid);

  static Future<CommissioningEndpoint> parseAndVerifyHost(
    String input, {
    required String hostId,
    required String hostPublicKey,
    required String bleServiceUuid,
  }) =>
      _parseAndVerify(
        input,
        expectedServiceUuid: bleServiceUuid,
        expectedHostId: hostId,
        expectedHostPublicKey: hostPublicKey,
      );

  static Future<CommissioningEndpoint> _parseAndVerify(
    String input, {
    required String expectedServiceUuid,
    String? expectedHostId,
    String? expectedHostPublicKey,
  }) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(input);
    } on FormatException {
      throw const SetupTrustException('附近主机返回了无效的身份数据');
    }
    if (decoded is! Map<String, dynamic> ||
        !_keys.every(decoded.containsKey) ||
        !decoded.keys.every(
          (key) => _keys.contains(key) || _optionalKeys.contains(key),
        )) {
      throw const SetupTrustException('附近主机的身份数据与 v1 契约不一致');
    }
    final contractVersion = _requiredJsonString(decoded, 'contract_version');
    final purpose = _requiredJsonString(decoded, 'purpose');
    final hostPublicKey = _requiredJsonString(decoded, 'host_public_key');
    final resetEpoch = _requiredJsonInt(decoded, 'reset_epoch');
    final fingerprint = _requiredJsonString(decoded, 'tls_spki_fingerprint');
    final signature = _requiredJsonString(decoded, 'signature');
    if (contractVersion != '1' ||
        purpose != _purpose ||
        !_uuidPattern.hasMatch(expectedServiceUuid) ||
        resetEpoch < 0 ||
        !RegExp(r'^sha256:[A-Za-z0-9_-]{43}$').hasMatch(fingerprint)) {
      throw const SetupTrustException('附近主机返回了无效的 Host endpoint');
    }
    final publicKey = _decodeBase64Url(hostPublicKey);
    final signatureBytes = _decodeBase64Url(signature);
    if (publicKey.length != 32 || signatureBytes.length != 64) {
      throw const SetupTrustException('附近主机的身份签名长度无效');
    }
    final digest = await Sha256().hash(publicKey);
    final derivedHostId = 'ehost-${_hex(digest.bytes).substring(0, 20)}';
    final derivedFingerprint = 'sha256:${_encodeBase64Url(digest.bytes)}';
    if ((expectedHostId != null && derivedHostId != expectedHostId) ||
        (expectedHostPublicKey != null &&
            hostPublicKey != expectedHostPublicKey)) {
      throw const SetupTrustException('附近主机与已保存的 Host 身份不匹配');
    }
    final unsigned = Map<String, dynamic>.from(decoded)..remove('signature');
    final verified = await Ed25519().verify(
      utf8.encode(jsonEncode(_canonicalize(unsigned))),
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
    if (!verified) {
      throw const SetupTrustException('附近主机未能证明目标 Host 身份');
    }
    final developmentSetup = DevelopmentSetupSession.fromJsonValueOrNull(
      decoded['setup_session'],
    );
    return CommissioningEndpoint._(
      hostId: derivedHostId,
      hostPublicKey: hostPublicKey,
      hostPublicKeyFingerprint: derivedFingerprint,
      resetEpoch: resetEpoch,
      bleServiceUuid: expectedServiceUuid,
      tlsSpkiFingerprint: fingerprint,
      developmentSetup: developmentSetup,
      localApiBaseUrls: _publishedBaseUrls(decoded['local_api_base_urls']),
    );
  }

  static List<String> _publishedBaseUrls(Object? value) {
    // A Host that has not been told where it answers publishes nothing rather
    // than a guess, and an entry that is not a usable HTTPS origin is dropped
    // rather than carried to the point of use.
    if (value is! List) return const [];
    return value
        .whereType<String>()
        .where((url) {
          final uri = Uri.tryParse(url);
          return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
        })
        .toList(growable: false);
  }

  final String hostId;
  final String hostPublicKey;
  final String hostPublicKeyFingerprint;
  final int resetEpoch;
  final String bleServiceUuid;
  final String tlsSpkiFingerprint;
  final DevelopmentSetupSession? developmentSetup;

  /// Where this Host says it answers, told over a channel that does not need
  /// the network to carry announcements — which is the one moment a phone
  /// cannot learn it any other way. Inside the signature, so it cannot be
  /// substituted; still only a place to look, since whatever answers there
  /// proves its identity like anything else.
  final List<String> localApiBaseUrls;
}

class DevelopmentSetupSession {
  const DevelopmentSetupSession({
    required this.commissioningId,
    required this.expiresAt,
  });

  factory DevelopmentSetupSession.fromJsonValue(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 2 ||
        !value.keys.every({'commissioning_id', 'expires_at'}.contains)) {
      throw const SetupTrustException('附近主机返回了无效的开发 Setup 状态');
    }
    final commissioningId = _requiredJsonString(value, 'commissioning_id');
    final expiresAt =
        DateTime.tryParse(_requiredJsonString(value, 'expires_at'));
    if (!CommissioningEndpoint._uuidPattern.hasMatch(commissioningId) ||
        expiresAt == null) {
      throw const SetupTrustException('附近主机返回了无效的开发 Setup 状态');
    }
    return DevelopmentSetupSession(
      commissioningId: commissioningId,
      expiresAt: expiresAt.toUtc(),
    );
  }

  static DevelopmentSetupSession? fromJsonValueOrNull(Object? value) {
    if (value == null) return null;
    return DevelopmentSetupSession.fromJsonValue(value);
  }

  final String commissioningId;
  final DateTime expiresAt;
}

class CommissioningRequestException implements Exception {
  const CommissioningRequestException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

String _requiredString(Map<Object?, Object?> value, String key) {
  final result = value[key];
  if (result is! String || result.isEmpty) {
    throw FormatException('Platform result is missing $key');
  }
  return result;
}

int _requiredInt(Map<Object?, Object?> value, String key) {
  final result = value[key];
  if (result is! int) throw FormatException('Platform result is missing $key');
  return result;
}

String _requiredJsonString(Map<String, dynamic> value, String key) {
  final result = value[key];
  if (result is! String || result.isEmpty) {
    throw FormatException('Commissioning response is missing $key');
  }
  return result;
}

int _requiredJsonInt(Map<String, dynamic> value, String key) {
  final result = value[key];
  if (result is! int) {
    throw FormatException('Commissioning response is missing $key');
  }
  return result;
}

bool _requiredJsonBool(Map<String, dynamic> value, String key) {
  final result = value[key];
  if (result is! bool) {
    throw FormatException('Commissioning response is missing $key');
  }
  return result;
}

List<int> _decodeBase64Url(String value) {
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    throw const SetupTrustException('附近主机的身份签名编码无效');
  }
}

String _encodeBase64Url(List<int> value) =>
    base64Url.encode(value).replaceAll('=', '');

String _hex(List<int> value) =>
    value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

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
