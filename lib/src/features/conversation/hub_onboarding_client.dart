import 'dart:collection';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../host_setup/pinned_http_client.dart';
import 'hub_onboarding_models.dart';
import 'mobile_body_security.dart';

typedef HubPinnedClientFactory = http.Client Function(String fingerprint);

class HubOnboardingRequestException implements Exception {
  const HubOnboardingRequestException({
    required this.operation,
    required this.message,
    this.statusCode,
  });

  final String operation;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class HubOnboardingClient {
  HubOnboardingClient({
    required MobileBodySecurity security,
    HubPinnedClientFactory? clientFactory,
    this.timeout = const Duration(seconds: 8),
  })  : _security = security,
        _clientFactory = clientFactory ??
            ((fingerprint) => PlatformPinnedHttpClient(
                  tlsSpkiFingerprint: fingerprint,
                ));

  final MobileBodySecurity _security;
  final HubPinnedClientFactory _clientFactory;
  final Duration timeout;

  Future<HubOnboardingDescriptor> fetchDescriptor(
    VerifiedHubTarget target,
  ) async {
    target.validate();
    final response = await _send(
      target,
      operation: 'Hub descriptor',
      uri: target.descriptorUri,
      request: (client, uri) => client.get(
        uri,
        headers: const {'accept': 'application/json'},
      ),
    );
    final value = _decode(response, operation: 'Hub descriptor');
    final descriptor = HubOnboardingDescriptor.fromJson(value);
    if (descriptor.hubId != target.hubId ||
        descriptor.descriptorUri != target.descriptorUri ||
        !_sameOrigin(descriptor.descriptorUri, descriptor.onboardingUri) ||
        !_sameOrigin(descriptor.descriptorUri, descriptor.enrollmentUri)) {
      throw const HubOnboardingRequestException(
        operation: 'Hub descriptor',
        message: 'Hub descriptor 与主机确认的 Hub 身份不一致',
      );
    }
    return descriptor;
  }

  Future<HubEnrollmentReceipt> enroll({
    required VerifiedHubTarget target,
    required HubOnboardingDescriptor descriptor,
    required DeviceEnrollmentMaterial material,
    required String deviceId,
    required String displayName,
    required String deviceKind,
    required Map<String, dynamic> manifest,
  }) async {
    _validateDescriptorTarget(target, descriptor);
    _bounded(deviceId, 'deviceId', 128);
    _bounded(displayName, 'displayName', 128, allowEmpty: true);
    _bounded(deviceKind, 'deviceKind', 96);
    final response = await _send(
      target,
      operation: 'Device enrollment',
      uri: descriptor.enrollmentUri,
      request: (client, uri) => client.post(
        uri,
        headers: const {
          'accept': 'application/json',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'operation': 'device.enrollment',
          'request_id': material.enrollmentRequestId,
          'retrieval_token': material.retrievalToken,
          'identity': {'device_id': deviceId},
          'manifest': manifest,
          'display_name': displayName,
          'device_kind': deviceKind,
        }),
      ),
    );
    final receipt = HubEnrollmentReceipt.fromJson(
      _decode(response, operation: 'Device enrollment'),
    );
    if (receipt.requestId != material.enrollmentRequestId ||
        receipt.deviceId != deviceId ||
        receipt.lifecycle != HubDeviceLifecycle.pendingApproval) {
      throw const HubOnboardingRequestException(
        operation: 'Device enrollment',
        message: 'Hub 返回了不属于本机的 Enrollment',
      );
    }
    await _security.saveEnrollmentReceipt(
      hubId: target.hubId,
      enrollmentId: receipt.enrollmentId,
      retrievalExpiresAt: receipt.retrievalExpiresAt,
    );
    return receipt;
  }

  Future<HubHandoffOutcome> handoff({
    required VerifiedHubTarget target,
    required HubOnboardingDescriptor descriptor,
    required DeviceEnrollmentMaterial material,
    required String deviceId,
    required String enrollmentId,
  }) async {
    _validateDescriptorTarget(target, descriptor);
    _bounded(enrollmentId, 'enrollmentId', 128);
    final handoffUri = descriptor.enrollmentUri.replace(
      pathSegments: [
        ...descriptor.enrollmentUri.pathSegments,
        enrollmentId,
        'handoff',
      ],
      query: null,
      fragment: null,
    );
    final response = await _send(
      target,
      operation: 'Device handoff',
      acceptedStatusCodes: const {200, 202},
      uri: handoffUri,
      request: (client, uri) => client.post(
        uri,
        headers: const {
          'accept': 'application/json',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'operation': 'device.handoff',
          'request_id': material.handoffRequestId,
          'retrieval_token': material.retrievalToken,
        }),
      ),
    );
    final outcome = HubHandoffOutcome.fromJson(
      _decode(response, operation: 'Device handoff'),
    );
    if (outcome.requestId != material.handoffRequestId ||
        outcome.enrollmentId != enrollmentId ||
        outcome.deviceId != deviceId ||
        (response.statusCode == 202 && !outcome.isPending) ||
        (response.statusCode == 200 &&
            outcome.lifecycle == HubDeviceLifecycle.pendingApproval)) {
      throw const HubOnboardingRequestException(
        operation: 'Device handoff',
        message: 'Hub 返回了不属于本次 Enrollment 的 Handoff',
      );
    }
    return outcome;
  }

  /// Issues [request] against [uri], dialled the way [target] says to.
  ///
  /// The URI goes through here rather than through each caller so that no
  /// request can be built that reaches the network by name.
  Future<http.Response> _send(
    VerifiedHubTarget target, {
    required String operation,
    required Uri uri,
    required Future<http.Response> Function(http.Client client, Uri uri)
        request,
    Set<int> acceptedStatusCodes = const {200},
  }) async {
    final client = _clientFactory(target.tlsSpkiFingerprint);
    try {
      final response = await request(client, target.dial(uri)).timeout(timeout);
      if (!acceptedStatusCodes.contains(response.statusCode)) {
        throw HubOnboardingRequestException(
          operation: operation,
          statusCode: response.statusCode,
          message:
              '$operation 返回 HTTP ${response.statusCode}：${_detail(response)}',
        );
      }
      return response;
    } on HubOnboardingRequestException {
      rethrow;
    } on PinnedHttpException catch (error) {
      throw HubOnboardingRequestException(
        operation: operation,
        message: switch (error.kind) {
          PinnedHttpFailureKind.secureChannel => 'Hub TLS 身份验证失败，已拒绝连接',
          PinnedHttpFailureKind.timeout => 'Hub 响应超时',
          PinnedHttpFailureKind.unreachable => '当前网络无法连接 Hub',
          _ => '$operation 失败：${error.message}',
        },
      );
    } on http.ClientException catch (error) {
      throw HubOnboardingRequestException(
        operation: operation,
        message: '$operation 网络失败：${error.message}',
      );
    } finally {
      client.close();
    }
  }

  Map<String, dynamic> _decode(
    http.Response response, {
    required String operation,
  }) {
    try {
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is Map) return Map<String, dynamic>.from(value);
    } on FormatException {
      // Throw the bounded operation-specific error below.
    }
    throw HubOnboardingRequestException(
      operation: operation,
      message: '$operation 返回的数据不是有效 JSON object',
    );
  }

  String _detail(http.Response response) {
    try {
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is Map && value['detail'] is String) {
        return (value['detail'] as String).substring(
          0,
          (value['detail'] as String).length.clamp(0, 180),
        );
      }
    } on FormatException {
      // Fall through.
    }
    return '请求失败';
  }

  void _validateDescriptorTarget(
    VerifiedHubTarget target,
    HubOnboardingDescriptor descriptor,
  ) {
    target.validate();
    if (descriptor.hubId != target.hubId ||
        descriptor.descriptorUri != target.descriptorUri ||
        !_sameOrigin(descriptor.descriptorUri, descriptor.enrollmentUri)) {
      throw const HubOnboardingRequestException(
        operation: 'Hub descriptor',
        message: 'Hub onboarding target 已变化，请重新连接主机',
      );
    }
  }
}

Future<String> canonicalManifestRevision(Map<String, dynamic> manifest) async {
  final canonical = jsonEncode(_canonicalJson(manifest));
  return _sha256Label(canonical);
}

Object? _canonicalJson(Object? value) {
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  if (value is List) {
    return value.map(_canonicalJson).toList(growable: false);
  }
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw const FormatException('Manifest JSON keys must be strings');
    }
    final keys = value.keys.cast<String>().toList()..sort();
    return LinkedHashMap<String, Object?>.fromEntries(
      keys.map(
        (key) => MapEntry(key, _canonicalJson(value[key])),
      ),
    );
  }
  throw const FormatException('Manifest contains a non-JSON value');
}

Future<String> _sha256Label(String value) async {
  final digest = await Sha256().hash(utf8.encode(value));
  final hex =
      digest.bytes.map((item) => item.toRadixString(16).padLeft(2, '0')).join();
  return 'sha256:$hex';
}

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme == right.scheme &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    left.port == right.port;

void _bounded(
  String value,
  String field,
  int maxLength, {
  bool allowEmpty = false,
}) {
  if ((!allowEmpty && value.isEmpty) || value.length > maxLength) {
    throw FormatException('$field is invalid');
  }
}
