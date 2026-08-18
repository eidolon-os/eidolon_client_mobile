import 'dart:collection';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../host_setup/pinned_http_client.dart';
import '../../generated/device_foundation_v1.dart';
import 'hub_onboarding_models.dart';
import 'mobile_body_security.dart';

typedef OwnerDomainClientFactory = http.Client Function(
  String ownerRootCertificate,
);

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
    OwnerDomainClientFactory? clientFactory,
    this.timeout = const Duration(seconds: 8),
  })  : _security = security,
        _clientFactory = clientFactory ??
            ((ownerRootCertificate) => PlatformPinnedHttpClient.ownerDomain(
                  ownerRootCertificate: ownerRootCertificate,
                ));

  final MobileBodySecurity _security;
  final OwnerDomainClientFactory _clientFactory;
  final Duration timeout;

  Future<OwnerDomainDescriptorV1> fetchDescriptor(
    VerifiedOwnerDomainTarget target,
  ) async {
    // The Controller already authenticated and verified this immutable signed
    // directory.  Mobile resolves logical Authorities from it; it never turns
    // the discovery URI or the current Host TLS leaf into persistent identity.
    target.admissionEndpoint();
    return target.descriptor;
  }

  Future<HubEnrollmentReceipt> enroll({
    required VerifiedOwnerDomainTarget target,
    required OwnerDomainDescriptorV1 descriptor,
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
      uri: _enrollmentsUri(target),
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
      ownerDomainId: target.ownerDomainId,
      enrollmentId: receipt.enrollmentId,
      retrievalExpiresAt: receipt.retrievalExpiresAt,
    );
    return receipt;
  }

  Future<HubHandoffOutcome> handoff({
    required VerifiedOwnerDomainTarget target,
    required OwnerDomainDescriptorV1 descriptor,
    required DeviceEnrollmentMaterial material,
    required String deviceId,
    required String enrollmentId,
  }) async {
    _validateDescriptorTarget(target, descriptor);
    _bounded(enrollmentId, 'enrollmentId', 128);
    final enrollmentsUri = _enrollmentsUri(target);
    final handoffUri = enrollmentsUri.replace(
      pathSegments: [
        ...enrollmentsUri.pathSegments,
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

  /// Issues [request] only through an endpoint authorized by the signed Owner
  /// directory, with normal hostname verification against the portable Owner
  /// root. Host addresses and leaf fingerprints are not identity inputs.
  Future<http.Response> _send(
    VerifiedOwnerDomainTarget target, {
    required String operation,
    required Uri uri,
    required Future<http.Response> Function(http.Client client, Uri uri)
        request,
    Set<int> acceptedStatusCodes = const {200},
  }) async {
    final client = _clientFactory(target.ownerRootCertificate);
    try {
      final response = await request(client, uri).timeout(timeout);
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
          PinnedHttpFailureKind.secureChannel =>
            'Owner Domain endpoint TLS 身份验证失败，已拒绝连接',
          PinnedHttpFailureKind.timeout => 'Owner Domain endpoint 响应超时',
          PinnedHttpFailureKind.unreachable => '当前网络无法连接 Owner Domain endpoint',
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
    VerifiedOwnerDomainTarget target,
    OwnerDomainDescriptorV1 descriptor,
  ) {
    if (descriptor.ownerDomainId != target.ownerDomainId ||
        descriptor.directoryRevision != target.descriptor.directoryRevision ||
        descriptor.signature != target.descriptor.signature) {
      throw const HubOnboardingRequestException(
        operation: 'Owner Domain descriptor',
        message: 'Owner Domain directory 已变化，请重新连接 Controller',
      );
    }
    target.admissionEndpoint();
  }

  Uri _enrollmentsUri(VerifiedOwnerDomainTarget target) {
    final base = target.admissionEndpoint().uri;
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((segment) => segment.isNotEmpty),
        'enrollments',
      ],
      query: null,
      fragment: null,
    );
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
