import 'dart:collection';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../host_setup/dev_descriptor.dart';

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

class CommissioningEndpoint {
  const CommissioningEndpoint._({
    required this.hostId,
    required this.resetEpoch,
    required this.bleServiceUuid,
    required this.tlsSpkiFingerprint,
  });

  static const _purpose = 'eidolon-ble-commissioning-endpoint-v1';
  static const _keys = <String>{
    'contract_version',
    'purpose',
    'host_id',
    'reset_epoch',
    'ble_service_uuid',
    'tls_spki_fingerprint',
    'signature',
  };

  static Future<CommissioningEndpoint> parseAndVerify(
    String input,
    DevelopmentCommissioningDescriptor credential,
  ) =>
      parseAndVerifyHost(
        input,
        hostId: credential.hostId,
        hostPublicKey: credential.hostPublicKey,
        bleServiceUuid: credential.bleServiceUuid,
      );

  static Future<CommissioningEndpoint> parseAndVerifyHost(
    String input, {
    required String hostId,
    required String hostPublicKey,
    required String bleServiceUuid,
  }) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(input);
    } on FormatException {
      throw const SetupTrustException('附近主机返回了无效的身份数据');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded.length != _keys.length ||
        !decoded.keys.every(_keys.contains)) {
      throw const SetupTrustException('附近主机的身份数据与 v1 契约不一致');
    }
    final contractVersion = _requiredJsonString(decoded, 'contract_version');
    final purpose = _requiredJsonString(decoded, 'purpose');
    final endpointHostId = _requiredJsonString(decoded, 'host_id');
    final serviceUuid = _requiredJsonString(decoded, 'ble_service_uuid');
    final resetEpoch = _requiredJsonInt(decoded, 'reset_epoch');
    final fingerprint = _requiredJsonString(decoded, 'tls_spki_fingerprint');
    final signature = _requiredJsonString(decoded, 'signature');
    if (contractVersion != '1' ||
        purpose != _purpose ||
        endpointHostId != hostId ||
        serviceUuid.toLowerCase() != bleServiceUuid.toLowerCase() ||
        resetEpoch < 0 ||
        !RegExp(r'^sha256:[A-Za-z0-9_-]{43}$').hasMatch(fingerprint)) {
      throw const SetupTrustException('附近主机与已验证的 Host 凭据不匹配');
    }
    final publicKey = _decodeBase64Url(hostPublicKey);
    final signatureBytes = _decodeBase64Url(signature);
    if (publicKey.length != 32 || signatureBytes.length != 64) {
      throw const SetupTrustException('附近主机的身份签名长度无效');
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
    return CommissioningEndpoint._(
      hostId: endpointHostId,
      resetEpoch: resetEpoch,
      bleServiceUuid: serviceUuid,
      tlsSpkiFingerprint: fingerprint,
    );
  }

  final String hostId;
  final int resetEpoch;
  final String bleServiceUuid;
  final String tlsSpkiFingerprint;
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
