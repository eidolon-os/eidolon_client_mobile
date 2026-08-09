import 'dart:convert';

import '../device_setup/device_setup_models.dart';

enum HubDeviceLifecycle { pendingApproval, approved, revoked }

/// Hub origin and TLS authority obtained through an authenticated Host session.
///
/// mDNS locates a Hub but is not a trust anchor. Product code must construct
/// this value only after the Host Local API has bound the Hub ID, descriptor
/// URI and SPKI fingerprint to the current Controller session.
class VerifiedHubTarget {
  const VerifiedHubTarget({
    required this.hubId,
    required this.descriptorUri,
    required this.tlsSpkiFingerprint,
  });

  final String hubId;
  final Uri descriptorUri;
  final String tlsSpkiFingerprint;

  factory VerifiedHubTarget.fromDeviceTarget(DeviceOnboardingTarget target) =>
      VerifiedHubTarget(
        hubId: target.hubId,
        descriptorUri: target.descriptorUri,
        tlsSpkiFingerprint: target.tlsSpkiFingerprint,
      );

  void validate() {
    if (hubId.isEmpty || hubId.length > 128) {
      throw const FormatException('Hub ID is invalid');
    }
    _requireHttpsUri(descriptorUri, field: 'descriptor URI');
    if (!RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(tlsSpkiFingerprint)) {
      throw const FormatException('Hub TLS SPKI fingerprint is invalid');
    }
  }
}

class HubOnboardingDescriptor {
  const HubOnboardingDescriptor({
    required this.hubId,
    required this.descriptorUri,
    required this.onboardingUri,
    required this.enrollmentUri,
    required this.protocolVersions,
  });

  final String hubId;
  final Uri descriptorUri;
  final Uri onboardingUri;
  final Uri enrollmentUri;
  final List<int> protocolVersions;

  factory HubOnboardingDescriptor.fromJson(Map<String, dynamic> value) {
    if (value['schema_version'] != 1) {
      throw const FormatException('Unsupported Hub descriptor schema');
    }
    final rawVersions = value['protocol_versions'];
    if (rawVersions is! List ||
        rawVersions.isEmpty ||
        rawVersions.length > 8 ||
        rawVersions.any((item) => item is! int)) {
      throw const FormatException('Hub protocol versions are invalid');
    }
    final descriptor = HubOnboardingDescriptor(
      hubId: _boundedString(value, 'hub_id', maxLength: 128),
      descriptorUri: _httpsUri(value, 'descriptor_uri'),
      onboardingUri: _httpsUri(value, 'device_onboarding_uri'),
      enrollmentUri: _httpsUri(value, 'enrollment_uri'),
      protocolVersions: List<int>.unmodifiable(rawVersions.cast<int>()),
    );
    if (!descriptor.protocolVersions.contains(1)) {
      throw const FormatException('Hub does not support onboarding v1');
    }
    return descriptor;
  }
}

class DeviceEnrollmentMaterial {
  const DeviceEnrollmentMaterial({
    required this.enrollmentRequestId,
    required this.handoffRequestId,
    required this.retrievalToken,
    required this.pairingSecret,
    this.enrollmentId,
    this.retrievalExpiresAt,
  });

  final String enrollmentRequestId;
  final String handoffRequestId;
  final String retrievalToken;
  final String? pairingSecret;
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
      pairingSecret: _optionalPlatformString(
        value,
        'pairingSecret',
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

class DeviceEnrollmentIdentityProof {
  const DeviceEnrollmentIdentityProof({
    required this.publicKeySpki,
    required this.signature,
  });

  final String publicKeySpki;
  final String signature;

  factory DeviceEnrollmentIdentityProof.fromMap(Map<Object?, Object?> value) =>
      DeviceEnrollmentIdentityProof(
        publicKeySpki: _base64UrlPlatformString(
          value,
          'publicKeySpki',
          minLength: 80,
          maxLength: 256,
        ),
        signature: _base64UrlPlatformString(
          value,
          'signature',
          minLength: 64,
          maxLength: 256,
        ),
      );
}

class HubEnrollmentReceipt {
  const HubEnrollmentReceipt({
    required this.requestId,
    required this.enrollmentId,
    required this.deviceId,
    required this.lifecycle,
    required this.retrievalExpiresAt,
    this.pairingClaimUri,
  });

  final String requestId;
  final String enrollmentId;
  final String deviceId;
  final HubDeviceLifecycle lifecycle;
  final DateTime retrievalExpiresAt;
  final Uri? pairingClaimUri;

  factory HubEnrollmentReceipt.fromJson(Map<String, dynamic> value) {
    if (value['operation'] != 'device.enrollment-received') {
      throw const FormatException('Hub enrollment receipt is invalid');
    }
    final expiresAt = value['retrieval_expires_at_ms'];
    if (expiresAt is! int || expiresAt < 0) {
      throw const FormatException('Hub enrollment expiry is invalid');
    }
    final rawClaimUri = value['pairing_claim_uri'];
    final claimUri = rawClaimUri == null
        ? null
        : rawClaimUri is String
            ? Uri.tryParse(rawClaimUri)
            : null;
    if (rawClaimUri != null && claimUri == null) {
      throw const FormatException('Hub pairing claim URI is invalid');
    }
    if (claimUri != null) {
      _requireHttpsUri(claimUri, field: 'pairing claim URI');
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
      pairingClaimUri: claimUri,
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

Uri _httpsUri(Map<String, dynamic> value, String key) {
  final raw = _boundedString(value, key, maxLength: 2048);
  final uri = Uri.tryParse(raw);
  if (uri == null) throw FormatException('Hub field $key is invalid');
  _requireHttpsUri(uri, field: key);
  return uri;
}

void _requireHttpsUri(Uri uri, {required String field}) {
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw FormatException('Hub $field must be a plain HTTPS URI');
  }
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

String _base64UrlPlatformString(
  Map<Object?, Object?> value,
  String key, {
  required int minLength,
  required int maxLength,
}) {
  final result = _boundedPlatformString(
    value,
    key,
    minLength: minLength,
    maxLength: maxLength,
  );
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(result)) {
    throw FormatException('Secure enrollment field $key is invalid');
  }
  return result;
}
