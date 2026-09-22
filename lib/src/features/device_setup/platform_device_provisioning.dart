import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../generated/device_foundation_v1.dart';
import 'device_setup_models.dart';
export 'device_setup_models.dart' show DeviceProvisioningTransportException;
import 'device_setup_ports.dart';

/// The provisioning transport as this app actually speaks it.
///
/// Underneath is protocomm — the same named endpoints whether the session runs
/// over BLE or over the device's own access point — but none of that reaches
/// [DeviceProvisioningTransport]. The wire format below belongs to this adapter,
/// not to the contract: a device class that speaks something else is another
/// adapter beside this one, and nothing above has to learn about it.
///
class PlatformDeviceProvisioning implements DeviceProvisioningTransport {
  PlatformDeviceProvisioning({
    MethodChannel? channel,
    DateTime Function()? clock,
  })  : _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform'),
        _clock = clock ?? DateTime.now;

  final MethodChannel _channel;
  final DateTime Function() _clock;

  void _requireAndroid() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw const DeviceProvisioningTransportException(
        'unsupported_platform',
        '设备配网目前先支持 Android;iPhone 版本将在协议稳定后接入。',
      );
    }
  }

  /// Say what the phone said, in words a person can act on.
  ///
  /// A platform failure carries a code because the Android half knows things
  /// this half cannot see — that Wi-Fi is off, that the system refused to scan.
  /// Letting the raw exception reach the screen would put a Java class name in
  /// front of someone holding a device that is sitting there waiting.
  static Never _translate(PlatformException error) {
    final message = switch (error.code) {
      'WIFI_DISABLED' => '请先打开手机的 Wi-Fi,设置设备要通过它。',
      // Android will not tell an app what is nearby unless location is on,
      // whatever permissions it holds. Nothing here reads a location, but the
      // scan does not happen without it.
      'LOCATION_SERVICES_OFF' => '请打开手机的定位开关。Android 不打开它就不让应用看到附近的设备。',
      'DEVICE_SCAN_STALE' => '手机刚才没能重新扫描一次,所以还不知道附近有什么。稍等几秒再试一次。',
      'DEVICE_SCAN_BUSY' => '正在扫描,请稍候。',
      'WIFI_PERMISSION_DENIED' => '设置设备需要「附近设备」权限。',
      'DEVICE_UNREACHABLE' => '连不上这台设备。请确认设备仍在网络设置模式，再重新连接。',
      'DEVICE_SESSION_FAILED' => _withDetail('已连接设备热点，但建立安全会话失败', error),
      'DEVICE_DISCONNECTED' => '设备中断了这次设置。请再试一次。',
      // The detail is kept. This one sentence has stood in front of three
      // unrelated faults so far, none of them the device's silence.
      'DESCRIPTOR_EMPTY' ||
      'DESCRIPTOR_UNAVAILABLE' =>
        _withDetail('没能读到设备的说明', error),
      'TRUST_UNANSWERED' => _withDetail('设备没有回应它是否接受了这个 Owner Domain', error),
      'DEVICE_REFUSED_NETWORK' ||
      'NETWORK_REJECTED' ||
      'NETWORK_CANDIDATE_REJECTED' ||
      'NETWORK_APPLY_REJECTED' =>
        '设备没有接受这个网络,请确认 Wi-Fi 名称和密码。',
      'COMMISSIONING_TERMINAL_TIMEOUT' => '未能在限定时间内取得配网结果，暂时无法确认是否已提交。',
      'COMMISSIONING_STATUS_UNAVAILABLE' ||
      'TERMINAL_ACK_FAILED' =>
        '设置连接中断，暂时无法确认配网结果。请查看设备状态。',
      _ => error.message ?? '设置设备时出错了。',
    };
    throw DeviceProvisioningTransportException(
      error.code.toLowerCase(),
      message,
    );
  }

  static String _withDetail(String sentence, PlatformException error) {
    final detail = error.message?.trim();
    return detail == null || detail.isEmpty
        ? '$sentence。'
        : '$sentence:$detail';
  }

  @override
  Future<bool> requestPermission() async {
    _requireAndroid();
    try {
      return await _channel
              .invokeMethod<bool>('requestDeviceProvisioningPermission') ??
          false;
    } on PlatformException catch (error) {
      _translate(error);
    }
  }

  @override
  Future<List<DeviceProvisioningCandidate>> discover() async {
    _requireAndroid();
    final List<Object?>? raw;
    try {
      raw = await _channel.invokeListMethod<Object?>(
        'discoverProvisionableDevices',
      );
    } on PlatformException catch (error) {
      _translate(error);
    }
    return (raw ?? const <Object?>[])
        .map((item) => _candidateFromPlatform(
              Map<Object?, Object?>.from(item! as Map),
            ))
        .toList(growable: false);
  }

  static int _nextVisit = 0;
  String? _activeVisit;
  bool _opening = false;

  @override
  Future<DeviceProvisioningSession> open(
    DeviceProvisioningCandidate candidate,
  ) async {
    _requireAndroid();
    if (_opening) {
      throw const DeviceProvisioningTransportException(
        'provisioning_busy', '正在连接设备，请稍候。',
      );
    }
    final visit = '${DateTime.now().microsecondsSinceEpoch}-${++_nextVisit}';
    final previousVisit = _activeVisit;
    _opening = true;
    _activeVisit = visit;
    try {
      final raw = await _channel.invokeMethod<String>(
        'openProvisioningSession',
        {'transportId': candidate.transportId, 'sessionId': visit},
      );
      if (_activeVisit != visit) {
        throw const DeviceProvisioningTransportException(
          'provisioning_closed', '这次设备连接已取消。',
        );
      }
      if (raw == null || raw.isEmpty) {
        throw const DeviceProvisioningTransportException(
          'descriptor_missing', '设备没有说明自己是什么,无法继续设置。',
        );
      }
      return _PlatformProvisioningSession(
        channel: _channel,
        sessionId: visit,
        descriptor: _parseDescriptor(raw, now: _clock()),
      );
    } catch (error) {
      if (_activeVisit == visit) {
        // A native busy refusal never replaced the preceding visit.
        _activeVisit = error is PlatformException && error.code == 'PROVISIONING_BUSY'
            ? previousVisit : null;
      }
      try {
        await _channel.invokeMethod<void>(
          'closeProvisioningSession', {'sessionId': visit},
        );
      } catch (_) {
        // Preserve the original open/descriptor error. Native failures own
        // cleanup too; this scoped close cannot invalidate a different visit.
      }
      if (error is PlatformException) _translate(error);
      rethrow;
    } finally {
      _opening = false;
    }
  }

  @override
  Future<void> close() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final visit = _activeVisit;
    _activeVisit = null;
    if (visit != null) {
      await _channel
          .invokeMethod<void>('closeProvisioningSession', {'sessionId': visit});
    }
  }
}

class _PlatformProvisioningSession implements DeviceProvisioningSession {
  _PlatformProvisioningSession({
    required MethodChannel channel,
    required this.sessionId,
    required this.descriptor,
  }) : _channel = channel;

  final MethodChannel _channel;
  final String sessionId;

  @override
  DeviceProvisioningDescriptor descriptor;

  @override
  Future<DeviceProvisioningDescriptor> prepareOwner(
      DeviceOnboardingTarget target) async {
    try {
      final raw =
          await _channel.invokeMethod<String>('provisioningHandOverTrust', {
        'sessionId': sessionId,
        'payloadJson': jsonEncode({
          'contract_version': '1',
          'prepare_only': true,
          'owner_domain_id': target.ownerDomainId,
          'owner_domain_descriptor': target.ownerDomainDescriptor.toJson(),
          'owner_root_certificate': target.ownerRootCertificate,
          'authority_signing_certificate': target.authoritySigningCertificate,
        }),
      });
      final value = raw == null ? null : jsonDecode(raw);
      if (value is! Map<String, dynamic> ||
          value['contract_version'] != '1' ||
          value['prepared'] != true ||
          value['owner_domain_id'] != target.ownerDomainId ||
          value['identity_fingerprint'] is! String ||
          !RegExp(r'^sha256:[0-9a-f]{64}$')
              .hasMatch(value['identity_fingerprint'] as String)) {
        throw const DeviceProvisioningTransportException(
            'owner_preparation_failed', '设备尚未完成归属准备，请保持配置连接后重试。');
      }
      final fingerprint = value['identity_fingerprint'] as String;
      if (value['device_id'] != 'device-instance-${fingerprint.substring(7)}') {
        throw const DeviceProvisioningTransportException(
            'owner_preparation_invalid', '设备返回的身份与配置钥匙不一致。');
      }
      descriptor = DeviceProvisioningDescriptor(
        setup: SetupDescriptorV1.fromJson({
          ...descriptor.setup.toJson(),
          'device_id': value['device_id'],
          'identity_fingerprint': 'p256:${fingerprint.substring(7)}',
        }),
        expiresAt: descriptor.expiresAt,
        requiresVoucher: value['requires_voucher'] != false,
      );
      return descriptor;
    } on PlatformException catch (error) {
      PlatformDeviceProvisioning._translate(error);
    }
  }

  @override
  Future<List<DeviceWifiNetwork>> scanNetworks() async {
    try {
      final raw = await _channel.invokeListMethod<Object?>(
        'provisioningScanNetworks',
        {'sessionId': sessionId},
      );
      return (raw ?? const <Object?>[])
          .map((item) => _networkFromPlatform(
                Map<Object?, Object?>.from(item! as Map),
              ))
          .toList(growable: false);
    } on PlatformException catch (error) {
      PlatformDeviceProvisioning._translate(error);
    }
  }

  @override
  Future<CommissioningStatusEvidenceV1> configureNetwork({
    required DeviceWifiCredentials credentials,
    required DeviceOnboardingTarget onboardingTarget,
    required String createCommandId,
    required String collectCommandId,
    required String ackCommandId,
  }) async {
    try {
      // Trust first, network second. The order is the controller's to enforce
      // because the controller is the party that knows it — and it matters twice
      // over: a device that joined a network without knowing its Host has nothing
      // it can safely talk to there, and the session that carries this handover is
      // exactly what joining may take down.
      final handover = await _channel.invokeMethod<String>(
        'provisioningHandOverTrust',
        {
          'sessionId': sessionId,
          'payloadJson': jsonEncode({
            'contract_version': '1',
            'owner_domain_id': onboardingTarget.ownerDomainId,
            'owner_domain_descriptor':
                onboardingTarget.ownerDomainDescriptor.toJson(),
            'owner_root_certificate': onboardingTarget.ownerRootCertificate,
            'authority_signing_certificate':
                onboardingTarget.authoritySigningCertificate,
            if (onboardingTarget.commissioningVoucher != null)
              'commissioning_voucher': onboardingTarget.commissioningVoucher,
            'admission_command_ids': {
              'create': createCommandId,
              'collect': collectCommandId,
              'ack': ackCommandId,
            },
          }),
        },
      );
      _requireStagedHandover(
        handover,
        expectedOwnerDomainId: onboardingTarget.ownerDomainId,
      );

      final rawEvidence = await _channel.invokeMapMethod<Object?, Object?>(
        'provisioningConfigureNetwork',
        {
          'sessionId': sessionId,
          'ssid': credentials.ssid,
          'password': credentials.password,
        },
      );
      if (rawEvidence == null) {
        throw const DeviceProvisioningTransportException(
          'network_terminal_missing',
          '设备没有确认已连接到新网络。',
        );
      }
      final CommissioningStatusEvidenceV1 evidence;
      try {
        evidence = CommissioningStatusEvidenceV1.fromJson(
          Map<String, dynamic>.from(rawEvidence),
        );
      } on FormatException {
        throw const DeviceProvisioningTransportException(
          'network_terminal_invalid',
          '设备返回的配网终态证据不符合 v1 契约。',
        );
      }
      if (!evidence.isCommittedTerminal ||
          evidence.sessionId != descriptor.sessionId) {
        throw const DeviceProvisioningTransportException(
          'network_terminal_invalid',
          '设备没有确认 Owner 可达且网络与信任已共同提交。',
        );
      }

      // The coordinator persists this committed fact before transport cleanup.
      // A failed close must never turn a successful network write into a retry.
      return evidence;
    } on PlatformException catch (error) {
      PlatformDeviceProvisioning._translate(error);
    }
  }

  void _requireStagedHandover(
    String? raw, {
    required String expectedOwnerDomainId,
  }) {
    if (raw == null || raw.isEmpty) {
      throw const DeviceProvisioningTransportException(
        'trust_handover_unanswered',
        '设备没有回应它是否接受了这个 Owner Domain。',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const DeviceProvisioningTransportException(
        'trust_handover_invalid',
        '设备对 Owner Domain 交接的回应无法解析。',
      );
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['contract_version'] != '1') {
      throw const DeviceProvisioningTransportException(
        'trust_handover_invalid',
        '设备返回的 Owner Domain 交接结果与 v1 契约不一致。',
      );
    }
    if (decoded['staged'] != true) {
      final error = decoded['error'];
      throw DeviceProvisioningTransportException(
        'trust_handover_refused',
        error is String && error.isNotEmpty
            ? '设备拒绝了这个 Owner Domain:$error'
            : '设备拒绝了这个 Owner Domain。',
      );
    }
    if (decoded['owner_domain_id'] != expectedOwnerDomainId) {
      throw const DeviceProvisioningTransportException(
        'trust_handover_mismatch',
        '设备确认的 Owner Domain 与本次设置不一致。',
      );
    }
  }

  @override
  Future<void> close() async {
    await _channel.invokeMethod<void>(
        'closeProvisioningSession', {'sessionId': sessionId});
  }
}

DeviceProvisioningCandidate _candidateFromPlatform(
    Map<Object?, Object?> value) {
  final transportId = value['transportId'];
  final displayName = value['displayName'];
  final transportKind = value['transportKind'];
  final signalStrength = value['signalStrength'];
  if (transportId is! String ||
      transportId.isEmpty ||
      transportId.length > 128 ||
      displayName is! String ||
      displayName.isEmpty ||
      displayName.length > 128 ||
      transportKind is! String ||
      transportKind.isEmpty) {
    throw const DeviceProvisioningTransportException(
      'invalid_candidate',
      '发现了一个无法识别的可配网设备。',
    );
  }
  return DeviceProvisioningCandidate(
    transportId: transportId,
    displayName: displayName,
    transportKind: transportKind,
    // Nothing discoverable proves a manufacturer-bound identity: only the
    // descriptor read over an authenticated session can, and the coordinator
    // refuses a session whose trust changed between the two.
    trust: SetupDescriptorTrustV1.developmentTofu,
    signalStrength: signalStrength is int ? signalStrength : null,
  );
}

DeviceWifiNetwork _networkFromPlatform(Map<Object?, Object?> value) {
  final ssid = value['ssid'];
  final signalStrength = value['signalStrength'];
  final security = value['security'];
  if (ssid is! String || ssid.isEmpty || ssid.length > 32) {
    throw const DeviceProvisioningTransportException(
      'invalid_network',
      '设备返回了一个无法使用的 Wi-Fi 名称。',
    );
  }
  return DeviceWifiNetwork(
    ssid: ssid,
    signalStrength: signalStrength is int ? signalStrength : 0,
    security: security is String && security.isNotEmpty ? security : 'unknown',
  );
}

/// Read the descriptor a device answers with over the provisioning session.
///
/// The field table and every rule about it belong to the generated canonical
/// binding. They used to live here as a hand-written check and in the firmware
/// as hand-written JSON, kept in step by review: the device encoded "this offer
/// never ends" as `expires_in_seconds: 0`, this side required a duration it
/// could act on, and every device out of the box was refused for breaking a
/// contract neither end had broken.
///
/// What is left here is the one thing the device could not tell us. It reports
/// how long its window lasts rather than when it ends — it has not joined a
/// network and has no clock to name an instant with — so the absolute expiry is
/// computed here, against the clock of the phone that is doing the asking. An
/// offer with no duration stays an offer with no deadline all the way through,
/// rather than becoming one that has already lapsed.
DeviceProvisioningDescriptor _parseDescriptor(String raw,
    {required DateTime now}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    // Not the same answer as a descriptor that parsed and said the wrong
    // thing: this one never reached the contract at all.
    throw const DeviceProvisioningTransportException(
      'descriptor_invalid',
      '设备返回的说明无法解析。',
    );
  }
  final SetupDescriptorV1 setup;
  try {
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('descriptor is not an object');
    }
    setup = SetupDescriptorV1.fromJson(decoded);
  } on FormatException {
    throw const DeviceProvisioningTransportException(
      'descriptor_invalid',
      '设备返回的说明与 v1 契约不一致。',
    );
  }
  final expiresIn = setup.expiresIn;
  return DeviceProvisioningDescriptor(
    setup: setup,
    expiresAt: expiresIn == null
        ? null
        : now.add(Duration(seconds: expiresIn.seconds)),
  );
}
