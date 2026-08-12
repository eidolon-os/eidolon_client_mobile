import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../models/hub_models.dart';
import '../../platform/platform_bridge.dart';
import '../device_setup/device_setup_models.dart';
import 'conversation_provisioner.dart';
import 'hub_onboarding_client.dart';
import 'hub_onboarding_models.dart';
import 'mobile_body_security.dart';

const mobileLiveKitBindingFormat =
    'application/vnd.eidolon.livekit-device+json;v=1';

typedef DeviceOnboardingTargetLoader = Future<DeviceOnboardingTarget>
    Function();
typedef MobileBodyAdmissionApproval = Future<DeviceAdmissionProgress> Function({
  required String requestId,
  required String deviceId,
});

/// Current Mobile body onboarding: authenticated Host target -> Hub enrollment
/// -> Owner-scoped Local API claim -> Hub handoff -> Provider binding.
///
/// The Local API owns Owner/Companion orchestration. Hub owns Device identity
/// and lifecycle. The Provider alone owns LiveKit credentials.
class MobileConversationProvisioner implements ConversationProvisioner {
  MobileConversationProvisioner({
    required DeviceOnboardingTargetLoader loadTarget,
    required MobileBodyAdmissionApproval approveAdmission,
    PlatformBridge? platform,
    MobileBodySecurity? security,
    HubOnboardingClient? hubClient,
    DateTime Function()? clock,
  })  : _loadTarget = loadTarget,
        _approveAdmission = approveAdmission,
        _platform = platform ?? const PlatformBridge(),
        _security = security ?? const PlatformMobileBodySecurity(),
        _hubClient = hubClient ??
            HubOnboardingClient(
              security: security ?? const PlatformMobileBodySecurity(),
            ),
        _clock = clock ?? DateTime.now;

  final DeviceOnboardingTargetLoader _loadTarget;
  final MobileBodyAdmissionApproval _approveAdmission;
  final PlatformBridge _platform;
  final MobileBodySecurity _security;
  final HubOnboardingClient _hubClient;
  final DateTime Function() _clock;

  VerifiedHubTarget? _lastTarget;

  @override
  String get serviceName => _lastTarget?.hubId ?? 'Eidolon Hub';

  @override
  Uri get serviceUri =>
      _lastTarget?.descriptorUri ?? Uri.parse('https://eidolon.invalid/');

  @override
  Future<HubConfig> provision({String sessionIntent = ''}) async {
    final deviceTarget = await _loadTarget();
    final target = VerifiedHubTarget.fromDeviceTarget(deviceTarget)..validate();
    _lastTarget = target;
    final descriptor = await _hubClient.fetchDescriptor(target);
    final identity = await _platform.getDeviceIdentity();
    final material = await _security.loadOrCreateMaterial(target.hubId);

    try {
      return await _admitAndHandoff(target, descriptor, material, identity);
    } on HubOnboardingRequestException catch (error) {
      if (!_enrollmentIsGone(error)) rethrow;
      // The Hub no longer recognises this enrollment — the pickup window
      // closed before anyone approved it, or the record is gone. Only the
      // Hub saying so justifies discarding local material; a local clock
      // reading "expired" does not, because an approved device stays in
      // service and re-enrolling one is refused.
      await _security.clearMaterial(target.hubId);
      final fresh = await _security.loadOrCreateMaterial(target.hubId);
      return _admitAndHandoff(target, descriptor, fresh, identity);
    }
  }

  Future<HubConfig> _admitAndHandoff(
    VerifiedHubTarget target,
    HubOnboardingDescriptor descriptor,
    DeviceEnrollmentMaterial material,
    DeviceIdentity identity,
  ) async {
    var enrollmentId = material.enrollmentId;
    if (enrollmentId == null) {
      final receipt = await _enroll(
        target: target,
        descriptor: descriptor,
        material: material,
        deviceId: identity.deviceId,
      );
      enrollmentId = receipt.enrollmentId;
    }

    final requestId = await _approvalRequestId(
      hubId: target.hubId,
      deviceId: identity.deviceId,
      enrollmentId: enrollmentId,
    );
    final progress = await _approveAdmission(
      requestId: requestId,
      deviceId: identity.deviceId,
    );
    _validateAdmission(
      progress,
      deviceId: identity.deviceId,
      requestId: requestId,
    );
    if (progress.state == DeviceAdmissionState.failed) {
      throw StateError('移动设备接入未完成：${progress.completedStage}');
    }
    if (progress.state != DeviceAdmissionState.ready) {
      return _waitingConfig(identity);
    }

    final expectedRevision = await canonicalManifestRevision(
      mobileBodyManifest,
    );
    try {
      final outcome = await _hubClient.handoff(
        target: target,
        descriptor: descriptor,
        material: material,
        deviceId: identity.deviceId,
        enrollmentId: enrollmentId,
      );
      if (outcome.manifestRevision != expectedRevision) {
        throw const FormatException('Hub handoff 的 Mobile manifest 已变化');
      }
      if (outcome.lifecycle == HubDeviceLifecycle.revoked) {
        return _emptyConfig(
          HubConfigStatus.revoked,
          identity: identity,
        );
      }
      if (outcome.isPending) {
        return _emptyConfig(
          HubConfigStatus.pendingApproval,
          identity: identity,
        );
      }
      return _bindingConfig(outcome, identity);
    } on HubOnboardingRequestException catch (error) {
      if (error.statusCode == 502 || error.statusCode == 503) {
        return _waitingConfig(identity);
      }
      rethrow;
    }
  }

  Future<HubEnrollmentReceipt> _enroll({
    required VerifiedHubTarget target,
    required HubOnboardingDescriptor descriptor,
    required DeviceEnrollmentMaterial material,
    required String deviceId,
  }) async {
    try {
      return await _hubClient.enroll(
        target: target,
        descriptor: descriptor,
        material: material,
        deviceId: deviceId,
        displayName: 'Eidolon Mobile',
        deviceKind: 'mobile-android',
        manifest: mobileBodyManifest,
      );
    } on HubOnboardingRequestException catch (error) {
      if (error.statusCode != 409) rethrow;
      // The Host still holds this device, but this phone no longer has the
      // material that proves it is that device. Only the owner can resolve
      // that, by removing the device so it can be added again.
      throw StateError('这台设备已在 Host 上登记，但本机凭据已失效；请在管理端移除该设备后重新添加');
    }
  }

  bool _enrollmentIsGone(HubOnboardingRequestException error) =>
      error.operation == 'Device handoff' &&
      (error.statusCode == 404 || error.statusCode == 410);

  Future<String> _approvalRequestId({
    required String hubId,
    required String deviceId,
    required String enrollmentId,
  }) async {
    final digest = await Sha256().hash(
      utf8.encode('$hubId\n$deviceId\n$enrollmentId'),
    );
    final suffix = base64UrlEncode(digest.bytes).replaceAll('=', '');
    return 'mobile-body-approval-$suffix';
  }

  void _validateAdmission(
    DeviceAdmissionProgress progress, {
    required String deviceId,
    required String requestId,
  }) {
    if (progress.deviceId != deviceId || progress.requestId != requestId) {
      throw const FormatException('Local API 返回了不属于当前 Mobile 的接入状态');
    }
  }

  HubConfig _bindingConfig(
    HubHandoffOutcome outcome,
    DeviceIdentity identity,
  ) {
    final now = _clock().toUtc();
    for (final assignment in outcome.channels) {
      if (assignment.bindingFormat != mobileLiveKitBindingFormat ||
          !assignment.expiresAt.isAfter(now)) {
        continue;
      }
      final binding = _decodeBinding(assignment.opaqueBinding);
      return HubConfig(
        status: HubConfigStatus.active,
        active: binding.active,
        control: binding.control,
        registrationId: assignment.channelId,
        deviceFingerprint: identity.fingerprint,
        sampleRate: binding.sampleRate,
        channels: binding.channels,
      );
    }
    return _waitingConfig(identity);
  }

  _MobileLiveKitBinding _decodeBinding(List<int> bytes) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('Provider 返回了无效的 Mobile LiveKit binding');
    }
    if (decoded is! Map) {
      throw const FormatException('Provider 返回了无效的 Mobile LiveKit binding');
    }
    final value = Map<String, dynamic>.from(decoded);
    if (value['schema_version'] != 1 || value['audio'] is! Map) {
      throw const FormatException('Provider 返回了不兼容的 Mobile LiveKit binding');
    }
    final audio = Map<String, dynamic>.from(value['audio'] as Map);
    final sampleRate = audio['sample_rate'];
    final channels = audio['channels'];
    if (sampleRate is! int ||
        sampleRate < 8000 ||
        sampleRate > 48000 ||
        channels is! int ||
        channels < 1 ||
        channels > 2) {
      throw const FormatException('Provider 返回了无效的音频参数');
    }
    return _MobileLiveKitBinding(
      active: _room(value, 'active'),
      control: _room(value, 'control'),
      sampleRate: sampleRate,
      channels: channels,
    );
  }

  RoomConfig _room(Map<String, dynamic> value, String key) {
    final raw = value[key];
    if (raw is! Map) {
      throw FormatException('Provider binding 缺少 $key room');
    }
    final room = Map<String, dynamic>.from(raw);
    final serverUrl = _wireString(room, 'server_url', 2048);
    final uri = Uri.tryParse(serverUrl);
    if (uri == null ||
        !const {'ws', 'wss'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw FormatException('Provider binding 的 $key server_url 无效');
    }
    return RoomConfig(
      serverUrl: serverUrl,
      token: _wireString(room, 'token', 16384),
      identity: _wireString(room, 'identity', 256),
      roomName: _wireString(room, 'room_name', 256),
    );
  }

  String _wireString(
    Map<String, dynamic> value,
    String key,
    int maxLength,
  ) {
    final result = value[key];
    if (result is! String || result.isEmpty || result.length > maxLength) {
      throw FormatException('Provider binding 的 $key 无效');
    }
    return result;
  }

  HubConfig _waitingConfig(DeviceIdentity identity) => _emptyConfig(
        HubConfigStatus.waitingBinding,
        identity: identity,
      );

  HubConfig _emptyConfig(
    HubConfigStatus status, {
    required DeviceIdentity identity,
  }) =>
      HubConfig(
        status: status,
        active: const RoomConfig(
          serverUrl: '',
          token: '',
          identity: '',
          roomName: '',
        ),
        deviceFingerprint: identity.fingerprint,
      );
}

class _MobileLiveKitBinding {
  const _MobileLiveKitBinding({
    required this.active,
    required this.control,
    required this.sampleRate,
    required this.channels,
  });

  final RoomConfig active;
  final RoomConfig control;
  final int sampleRate;
  final int channels;
}

const mobileBodyManifest = <String, dynamic>{
  'schema_version': 1,
  'title': 'Eidolon Mobile',
  'properties': <Object>[],
  'actions': [
    {
      'name': 'device.identify',
      'version': 1,
      'input_schema': {
        'type': 'object',
        'properties': {
          'reason': {'type': 'string', 'maxLength': 128},
        },
        'additionalProperties': false,
      },
      'output_schema': {
        'type': 'object',
        'properties': {
          'played': {'type': 'boolean'},
        },
        'required': ['played'],
        'additionalProperties': false,
      },
      'idempotent': true,
    },
    {
      'name': 'body.presence.set',
      'version': 1,
      'input_schema': {
        'type': 'object',
        'properties': {
          'state': {
            'type': 'string',
            'enum': ['awake'],
          },
          'guard_epoch': {'type': 'integer', 'minimum': 0},
          'correlation_id': {'type': 'string', 'minLength': 1},
          'action_id': {'type': 'string', 'minLength': 1},
        },
        'required': [
          'state',
          'guard_epoch',
          'correlation_id',
          'action_id',
        ],
        'additionalProperties': false,
      },
      'output_schema': {
        'type': 'object',
        'properties': {
          'action_id': {'type': 'string'},
          'state': {
            'type': 'string',
            'enum': ['awake'],
          },
          'applied': {'type': 'boolean'},
        },
        'required': ['action_id', 'state', 'applied'],
        'additionalProperties': false,
      },
      'idempotent': false,
    },
  ],
  'events': <Object>[],
  'media': [
    {
      'kind': 'audio',
      'direction': 'bidirectional',
      'codecs': ['opus'],
    },
    {
      'kind': 'video',
      'direction': 'subscribe',
      'codecs': ['h264'],
    },
  ],
};
