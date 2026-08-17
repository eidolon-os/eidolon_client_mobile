import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
/// Whether the device enrolled is asked of the Host rather than of the device.
/// The enrollment is a fact the Host holds, the device only caused it, and over
/// an access-point session the answer could not travel anyway: joining the
/// network the Owner chose is what takes that session down.
typedef PendingEnrollmentLookup = Future<List<PendingDeviceEnrollment>> Function();

class DeviceProvisioningTransportException implements Exception {
  const DeviceProvisioningTransportException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class PlatformDeviceProvisioning implements DeviceProvisioningTransport {
  PlatformDeviceProvisioning({
    required PendingEnrollmentLookup loadPendingEnrollments,
    MethodChannel? channel,
    Duration enrollmentTimeout = const Duration(minutes: 3),
    Duration enrollmentInterval = const Duration(seconds: 3),
    DateTime Function()? clock,
  })  : _loadPendingEnrollments = loadPendingEnrollments,
        _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform'),
        _enrollmentTimeout = enrollmentTimeout,
        _enrollmentInterval = enrollmentInterval,
        _clock = clock ?? DateTime.now;

  final PendingEnrollmentLookup _loadPendingEnrollments;
  final MethodChannel _channel;
  final Duration _enrollmentTimeout;
  final Duration _enrollmentInterval;
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
      'LOCATION_SERVICES_OFF' =>
        '请打开手机的定位开关。Android 不打开它就不让应用看到附近的设备。',
      'DEVICE_SCAN_STALE' =>
        '手机刚才没能重新扫描一次,所以还不知道附近有什么。稍等几秒再试一次。',
      'DEVICE_SCAN_BUSY' => '正在扫描,请稍候。',
      'WIFI_PERMISSION_DENIED' => '设置设备需要「附近设备」权限。',
      'DEVICE_UNREACHABLE' =>
        '连不上这台设备。它的设置窗口可能已经超时,按一下它的按键再试。',
      'DEVICE_DISCONNECTED' => '设备中断了这次设置。请再试一次。',
      'DESCRIPTOR_EMPTY' || 'DESCRIPTOR_UNAVAILABLE' => '设备没有说明自己是什么。',
      'TRUST_UNANSWERED' => '设备没有回应它是否接受了这台 Host。',
      'DEVICE_REFUSED_NETWORK' || 'NETWORK_REJECTED' =>
        '设备没有接受这个网络,请确认 Wi-Fi 名称和密码。',
      _ => error.message ?? '设置设备时出错了。',
    };
    throw DeviceProvisioningTransportException(
      error.code.toLowerCase(),
      message,
    );
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
      loadPendingEnrollments: _loadPendingEnrollments,
      enrollmentTimeout: _enrollmentTimeout,
      enrollmentInterval: _enrollmentInterval,
      clock: _clock,
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
    required PendingEnrollmentLookup loadPendingEnrollments,
    required Duration enrollmentTimeout,
    required Duration enrollmentInterval,
    required DateTime Function() clock,
  })  : _channel = channel,
        _loadPendingEnrollments = loadPendingEnrollments,
        _enrollmentTimeout = enrollmentTimeout,
        _enrollmentInterval = enrollmentInterval,
        _clock = clock;

  final MethodChannel _channel;
  final PendingEnrollmentLookup _loadPendingEnrollments;
  final Duration _enrollmentTimeout;
  final Duration _enrollmentInterval;
  final DateTime Function() _clock;

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
  Future<void> configureNetwork({
    required DeviceWifiCredentials credentials,
    required DeviceOnboardingTarget onboardingTarget,
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
          'hub_id': onboardingTarget.hubId,
          'hub_certificate': onboardingTarget.hubCertificate,
        }),
      },
    );
    _requireAcceptedHandover(handover, expectedHubId: onboardingTarget.hubId);

    await _channel.invokeMethod<void>('provisioningConfigureNetwork', {
      'ssid': credentials.ssid,
      'password': credentials.password,
    });
  }

  void _requireAcceptedHandover(String? raw, {required String expectedHubId}) {
    if (raw == null || raw.isEmpty) {
      throw const DeviceProvisioningTransportException(
        'trust_handover_unanswered',
        '设备没有回应它是否接受了这台 Host。',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const DeviceProvisioningTransportException(
        'trust_handover_invalid',
        '设备对 Host 交接的回应无法解析。',
      );
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['contract_version'] != '1') {
      throw const DeviceProvisioningTransportException(
        'trust_handover_invalid',
        '设备返回的 Host 交接结果与 v1 契约不一致。',
      );
    }
    if (decoded['accepted'] != true) {
      final error = decoded['error'];
      throw DeviceProvisioningTransportException(
        'trust_handover_refused',
        error is String && error.isNotEmpty
            ? '设备拒绝了这台 Host:$error'
            : '设备拒绝了这台 Host。',
      );
    }
    // A device that echoed a different Host is not the device this setup is
    // configuring, and continuing would hand it a network it cannot use.
    if (decoded['hub_id'] != expectedHubId) {
      throw const DeviceProvisioningTransportException(
        'trust_handover_mismatch',
        '设备确认的 Host 与本次设置的 Host 不一致。',
      );
    }
  }

  @override
  Future<DeviceEnrollmentReceipt> awaitEnrollment() async {
    final deadline = _clock().add(_enrollmentTimeout);
    while (true) {
      final pending = await _loadPendingEnrollments();
      for (final entry in pending) {
        if (entry.deviceId == descriptor.deviceId) {
          return DeviceEnrollmentReceipt(
            deviceId: entry.deviceId,
            // The Host's pending answer says that this device enrolled, not
            // which enrollment it created. The identity check that matters is
            // on the device, and that is the field carried here.
            enrollmentId: '',
            lifecycleState: 'pending-approval',
          );
        }
      }
      if (!_clock().isBefore(deadline)) {
        throw const DeviceProvisioningTransportException(
          'enrollment_not_seen',
          '设备已收到网络与 Host,但还没有在 Host 上登记。请确认它已通电并在同一网络。',
        );
      }
      await Future<void>.delayed(_enrollmentInterval);
    }
  }

  @override
  Future<void> close() async {
    await _channel.invokeMethod<void>('closeProvisioningSession');
  }
}

DeviceProvisioningCandidate _candidateFromPlatform(Map<Object?, Object?> value) {
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
      sessionId.isEmpty ||
      expiresInSeconds is! int ||
      expiresInSeconds <= 0) {
    throw const DeviceProvisioningTransportException(
      'descriptor_invalid',
      '设备返回的说明与 v1 契约不一致。',
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
    expiresAt: now.add(Duration(seconds: expiresInSeconds)),
    trust: parsedTrust,
  );
}
