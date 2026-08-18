import 'dart:convert';

import '../device_setup/device_setup_models.dart';
import '../../generated/device_foundation_v1.dart';

enum HubDeviceLifecycle { pendingApproval, approved, revoked }

/// Owner-scoped route set obtained through an authenticated Controller session.
class VerifiedOwnerDomainTarget {
  const VerifiedOwnerDomainTarget({
    required this.ownerDomainId,
    required this.descriptor,
    required this.ownerRootCertificate,
  });

  final String ownerDomainId;
  final OwnerDomainDescriptorV1 descriptor;
  final String ownerRootCertificate;

  factory VerifiedOwnerDomainTarget.fromDeviceTarget(
    DeviceOnboardingTarget target,
  ) =>
      VerifiedOwnerDomainTarget(
        ownerDomainId: target.ownerDomainId,
        descriptor: target.ownerDomainDescriptor,
        ownerRootCertificate: target.ownerRootCertificate,
      );

  AuthorityEndpointV1 admissionEndpoint() {
    if (descriptor.ownerDomainId != ownerDomainId) {
      throw const FormatException(
          'Owner Domain descriptor identity is invalid');
    }
    final endpoints = descriptor.endpoints
        .where((item) =>
            item.authority == 'admission' &&
            item.logicalAudience == 'eidolon-admission' &&
            item.transportProfile == 'https-json')
        .toList(growable: false)
      ..sort((left, right) => left.priority.compareTo(right.priority));
    if (endpoints.isEmpty) {
      throw const FormatException('Owner Domain has no Admission endpoint');
    }
    return endpoints.first;
  }
}

class DeviceEnrollmentMaterial {
  const DeviceEnrollmentMaterial({
    required this.enrollmentRequestId,
    required this.handoffRequestId,
    required this.retrievalToken,
    this.enrollmentId,
    this.retrievalExpiresAt,
  });

  final String enrollmentRequestId;
  final String handoffRequestId;
  final String retrievalToken;
  final String? enrollmentId;
  final DateTime? retrievalExpiresAt;

  factory DeviceEnrollmentMaterial.fromMap(Map<Object?, Object?> value) {
    final expiresAtMs = value['retrievalExpiresAtMs'];
    return DeviceEnrollmentMaterial(
      enrollmentRequestId: _boundedPlatformString(
        value,
        'enrollmentRequestId',
        maxLength: 96,
      ),
      handoffRequestId: _boundedPlatformString(
        value,
        'handoffRequestId',
        maxLength: 96,
      ),
      retrievalToken: _boundedPlatformString(
        value,
        'retrievalToken',
        minLength: 32,
        maxLength: 256,
      ),
      enrollmentId: _optionalPlatformString(
        value,
        'enrollmentId',
        maxLength: 128,
      ),
      retrievalExpiresAt: expiresAtMs == null
          ? null
          : expiresAtMs is int && expiresAtMs >= 0
              ? DateTime.fromMillisecondsSinceEpoch(
                  expiresAtMs,
                  isUtc: true,
                )
              : throw const FormatException(
                  'Secure enrollment expiry is invalid',
                ),
    );
  }
}

class HubEnrollmentReceipt {
  const HubEnrollmentReceipt({
    required this.requestId,
    required this.enrollmentId,
    required this.deviceId,
    required this.lifecycle,
    required this.retrievalExpiresAt,
  });

  final String requestId;
  final String enrollmentId;
  final String deviceId;
  final HubDeviceLifecycle lifecycle;
  final DateTime retrievalExpiresAt;

  factory HubEnrollmentReceipt.fromJson(Map<String, dynamic> value) {
    if (value['operation'] != 'device.enrollment-received') {
      throw const FormatException('Hub enrollment receipt is invalid');
    }
    final expiresAt = value['retrieval_expires_at_ms'];
    if (expiresAt is! int || expiresAt < 0) {
      throw const FormatException('Hub enrollment expiry is invalid');
    }
    return HubEnrollmentReceipt(
      requestId: _boundedString(value, 'request_id', maxLength: 96),
      enrollmentId: _boundedString(value, 'enrollment_id', maxLength: 128),
      deviceId: _boundedString(value, 'device_id', maxLength: 128),
      lifecycle: _lifecycle(value['lifecycle_state']),
      retrievalExpiresAt: DateTime.fromMillisecondsSinceEpoch(
        expiresAt,
        isUtc: true,
      ),
    );
  }
}

class HubChannelAssignment {
  const HubChannelAssignment({
    required this.channelId,
    required this.purpose,
    required this.kinds,
    required this.bindingFormat,
    required this.issuedAt,
    required this.expiresAt,
    required this.opaqueBinding,
  });

  final String channelId;
  final String purpose;
  final List<String> kinds;
  final String bindingFormat;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final List<int> opaqueBinding;

  factory HubChannelAssignment.fromJson(Map<String, dynamic> value) {
    const allowedKinds = {
      'reliable-data',
      'realtime-data',
      'audio',
      'video',
    };
    final rawKinds = value['kinds'];
    if (rawKinds is! List ||
        rawKinds.isEmpty ||
        rawKinds.length > 4 ||
        rawKinds.any((item) => item is! String) ||
        rawKinds.toSet().length != rawKinds.length ||
        rawKinds.any((item) => !allowedKinds.contains(item))) {
      throw const FormatException('Hub channel kinds are invalid');
    }
    final issuedAtMs = value['issued_at_ms'];
    final expiresAtMs = value['expires_at_ms'];
    if (issuedAtMs is! int ||
        issuedAtMs < 0 ||
        expiresAtMs is! int ||
        expiresAtMs < issuedAtMs) {
      throw const FormatException('Hub channel lifetime is invalid');
    }
    final rawBinding = _boundedString(
      value,
      'opaque_binding',
      maxLength: 87384,
    );
    late final List<int> binding;
    try {
      binding = base64Decode(rawBinding);
    } on FormatException {
      throw const FormatException('Hub channel binding is not base64');
    }
    if (binding.isEmpty || binding.length > 65536) {
      throw const FormatException('Hub channel binding size is invalid');
    }
    return HubChannelAssignment(
      channelId: _boundedString(value, 'channel_id', maxLength: 128),
      purpose: _boundedString(value, 'purpose', maxLength: 96),
      kinds: List<String>.unmodifiable(rawKinds.cast<String>()),
      bindingFormat: _boundedString(
        value,
        'binding_format',
        maxLength: 128,
      ),
      issuedAt: DateTime.fromMillisecondsSinceEpoch(issuedAtMs, isUtc: true),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAtMs, isUtc: true),
      opaqueBinding: List<int>.unmodifiable(binding),
    );
  }
}

class HubHandoffOutcome {
  const HubHandoffOutcome({
    required this.requestId,
    required this.enrollmentId,
    required this.deviceId,
    required this.manifestRevision,
    required this.lifecycle,
    required this.channels,
  });

  final String requestId;
  final String enrollmentId;
  final String deviceId;
  final String manifestRevision;
  final HubDeviceLifecycle lifecycle;
  final List<HubChannelAssignment> channels;

  bool get isPending => lifecycle == HubDeviceLifecycle.pendingApproval;
  bool get isReady =>
      lifecycle == HubDeviceLifecycle.approved && channels.isNotEmpty;

  factory HubHandoffOutcome.fromJson(Map<String, dynamic> value) {
    if (value['operation'] != 'device.handoff-outcome') {
      throw const FormatException('Hub handoff outcome is invalid');
    }
    final rawChannels = value['channels'];
    if (rawChannels is! List || rawChannels.length > 16) {
      throw const FormatException('Hub channel assignments are invalid');
    }
    return HubHandoffOutcome(
      requestId: _boundedString(value, 'request_id', maxLength: 96),
      enrollmentId: _boundedString(value, 'enrollment_id', maxLength: 128),
      deviceId: _boundedString(value, 'device_id', maxLength: 128),
      manifestRevision: _boundedString(
        value,
        'manifest_revision',
        maxLength: 96,
      ),
      lifecycle: _lifecycle(value['lifecycle_state']),
      channels: List<HubChannelAssignment>.unmodifiable(
        rawChannels.map(
          (item) => item is Map
              ? HubChannelAssignment.fromJson(
                  Map<String, dynamic>.from(item),
                )
              : throw const FormatException(
                  'Hub channel assignment is invalid',
                ),
        ),
      ),
    );
  }
}

HubDeviceLifecycle _lifecycle(Object? value) => switch (value) {
      'pending-approval' => HubDeviceLifecycle.pendingApproval,
      'approved' => HubDeviceLifecycle.approved,
      'revoked' => HubDeviceLifecycle.revoked,
      _ => throw const FormatException('Hub lifecycle state is invalid'),
    };

String _boundedString(
  Map<String, dynamic> value,
  String key, {
  int minLength = 1,
  required int maxLength,
}) {
  final result = value[key];
  if (result is! String ||
      result.length < minLength ||
      result.length > maxLength) {
    throw FormatException('Hub field $key is invalid');
  }
  return result;
}

String _boundedPlatformString(
  Map<Object?, Object?> value,
  String key, {
  int minLength = 1,
  required int maxLength,
}) {
  final result = value[key];
  if (result is! String ||
      result.length < minLength ||
      result.length > maxLength) {
    throw FormatException('Secure enrollment field $key is invalid');
  }
  return result;
}

String? _optionalPlatformString(
  Map<Object?, Object?> value,
  String key, {
  int minLength = 1,
  required int maxLength,
}) {
  final result = value[key];
  if (result == null) return null;
  if (result is! String ||
      result.length < minLength ||
      result.length > maxLength) {
    throw FormatException('Secure enrollment field $key is invalid');
  }
  return result;
}
