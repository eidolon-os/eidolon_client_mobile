import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../generated/device_foundation_v1.dart';
import 'device_setup_models.dart';
import 'device_setup_ports.dart';

/// The provisioning transport as this app actually speaks it.
///
/// Underneath is protocomm — the same named endpoints whether the session runs
/// over BLE or over the device's own access point — but none of that reaches
/// [DeviceProvisioningTransport]. The wire format below belongs to this adapter,
/// not to the contract: a device class that speaks something else is another
/// adapter beside this one, and nothing above has to learn about it.
///
class DeviceProvisioningTransportException implements Exception {
  const DeviceProvisioningTransportException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

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
      'DEVICE_UNREACHABLE' => '连不上这台设备。它的设置窗口可能已经超时,按一下它的按键再试。',
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
      'COMMISSIONING_TERMINAL_TIMEOUT' =>
        '设备正在连接网络，但没有在限定时间内完成 Owner 验证；旧网络仍应保留。',
      'COMMISSIONING_STATUS_UNAVAILABLE' ||
      'TERMINAL_ACK_FAILED' =>
        '手机与设备的安全设置连接提前中断；不要复位设备，请重试。',
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

  @override
  Future<DeviceProvisioningSession> open(
    DeviceProvisioningCandidate candidate,
  ) async {
    _requireAndroid();
    final String? raw;
    try {
      raw = await _channel.invokeMethod<String>(
        'openProvisioningSession',
        {'transportId': candidate.transportId},
      );
    } on PlatformException catch (error) {
      _translate(error);
    }
    if (raw == null || raw.isEmpty) {
      throw const DeviceProvisioningTransportException(
        'descriptor_missing',
        '设备没有说明自己是什么,无法继续设置。',
      );
    }
    return _PlatformProvisioningSession(
      channel: _channel,
      descriptor: _parseDescriptor(raw, now: _clock()),
    );
  }

  @override
  Future<void> close() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('closeProvisioningSession');
  }
}

class _PlatformProvisioningSession implements DeviceProvisioningSession {
  _PlatformProvisioningSession({
    required MethodChannel channel,
    required this.descriptor,
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  final DeviceProvisioningDescriptor descriptor;

  @override
  Future<List<DeviceWifiNetwork>> scanNetworks() async {
    final raw = await _channel.invokeListMethod<Object?>(
      'provisioningScanNetworks',
    );
    return (raw ?? const <Object?>[])
        .map((item) => _networkFromPlatform(
              Map<Object?, Object?>.from(item! as Map),
            ))
        .toList(growable: false);
  }

  @override
  Future<CommissioningStatusEvidenceV1> configureNetwork({
    required DeviceWifiCredentials credentials,
    required DeviceOnboardingTarget onboardingTarget,
    required String createCommandId,
    required String collectCommandId,
    required String ackCommandId,
  }) async {
    // Trust first, network second. The order is the controller's to enforce
    // because the controller is the party that knows it — and it matters twice
    // over: a device that joined a network without knowing its Host has nothing
    // it can safely talk to there, and the session that carries this handover is
    // exactly what joining may take down.
    final handover = await _channel.invokeMethod<String>(
      'provisioningHandOverTrust',
      {
        'payloadJson': jsonEncode({
          'contract_version': '1',
          'owner_domain_id': onboardingTarget.ownerDomainId,
          'owner_domain_descriptor':
              onboardingTarget.ownerDomainDescriptor.toJson(),
          'owner_root_certificate': onboardingTarget.ownerRootCertificate,
          'authority_signing_certificate':
              onboardingTarget.authoritySigningCertificate,
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

    // The device is leaving its own access point to join the network it was just
    // given, so this session is over whether or not anyone closes it. Letting go
    // now is what puts the phone back on the Host's network — and the next thing
    // asked is a question only the Host can answer.
    await _channel.invokeMethod<void>('closeProvisioningSession');
    return evidence;
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
    await _channel.invokeMethod<void>('closeProvisioningSession');
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
    trust: DeviceProvisioningTrust.developmentTofu,
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
/// The device reports how long its window lasts rather than when it ends: it has
/// not joined a network and has no clock to name an instant with. The absolute
/// expiry the contract carries is therefore computed here, against the clock of
/// the phone that is doing the asking.
///
/// A device whose offer does not end reports no duration at all, and then there
/// is no instant to compute: an offer with no deadline stays an offer with no
/// deadline all the way through, rather than becoming one that has already
/// lapsed.
DeviceProvisioningDescriptor _parseDescriptor(String raw,
    {required DateTime now}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    throw const DeviceProvisioningTransportException(
      'descriptor_invalid',
      '设备返回的说明无法解析。',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw const DeviceProvisioningTransportException(
      'descriptor_invalid',
      '设备返回的说明不是一个 v1 描述符。',
    );
  }
  final contractVersion = decoded['contract_version'];
  final deviceId = decoded['device_id'];
  final deviceKind = decoded['device_kind'];
  final displayName = decoded['display_name'];
  final identityFingerprint = decoded['identity_fingerprint'];
  final sessionId = decoded['session_id'];
  final expiresInSeconds = decoded['expires_in_seconds'];
  final trust = decoded['trust'];
  if (contractVersion != '1' ||
      deviceId is! String ||
      deviceId.isEmpty ||
      deviceId.length > 128 ||
      deviceKind is! String ||
      deviceKind.isEmpty ||
      displayName is! String ||
      displayName.isEmpty ||
      identityFingerprint is! String ||
      identityFingerprint.isEmpty ||
      sessionId is! String ||
      sessionId.isEmpty) {
    throw const DeviceProvisioningTransportException(
      'descriptor_invalid',
      '设备返回的说明与 v1 契约不一致。',
    );
  }
  // Whether the offer ends at all is a separate fact from how long it lasts, so
  // it arrives separately: a device nobody has claimed keeps advertising until
  // it is claimed, cancelled or powered off, and says so by naming no duration.
  //
  // The absence is the whole of that answer. Devices used to encode it as 0,
  // and because a positive duration was required here, every device out of the
  // box was refused as breaking the contract. A duration that IS named must
  // still be one the device can honour: 0 or a negative one cannot be told
  // apart from a field nobody filled in, so it stays a refusal.
  final DateTime? expiresAt;
  if (expiresInSeconds == null) {
    expiresAt = null;
  } else if (expiresInSeconds is int && expiresInSeconds > 0) {
    expiresAt = now.add(Duration(seconds: expiresInSeconds));
  } else {
    throw const DeviceProvisioningTransportException(
      'descriptor_invalid',
      '设备声明的配网时限不是一个能用的时长。',
    );
  }
  final DeviceProvisioningTrust parsedTrust;
  switch (trust) {
    case 'manufacturer-bound':
      parsedTrust = DeviceProvisioningTrust.manufacturerBound;
    case 'development-tofu':
      parsedTrust = DeviceProvisioningTrust.developmentTofu;
    default:
      // A trust level this build does not know is not something to guess at in
      // the safe direction or the unsafe one.
      throw const DeviceProvisioningTransportException(
        'descriptor_invalid',
        '设备声明了一个本版本不认识的信任级别。',
      );
  }
  return DeviceProvisioningDescriptor(
    contractVersion: contractVersion as String,
    deviceId: deviceId,
    deviceKind: deviceKind,
    displayName: displayName,
    identityFingerprint: identityFingerprint,
    sessionId: sessionId,
    expiresAt: expiresAt,
    trust: parsedTrust,
  );
}
