enum HubConfigStatus {
  pendingApproval,
  waitingBinding,
  active,
  revoked,
  unregistered;

  static HubConfigStatus parse(String? value) => switch (value) {
        'active' => active,
        'waiting_binding' => waitingBinding,
        'revoked' => revoked,
        'unregistered' => unregistered,
        _ => pendingApproval,
      };

  String get wireValue => switch (this) {
        pendingApproval => 'pending_approval',
        waitingBinding => 'waiting_binding',
        active => 'active',
        revoked => 'revoked',
        unregistered => 'unregistered',
      };
}

class HubService {
  const HubService({
    required this.instanceName,
    required this.registerUrl,
    this.version = '',
    this.api = 'v1',
  });

  final String instanceName;
  final String registerUrl;
  final String version;
  final String api;

  factory HubService.fromMap(Map<Object?, Object?> map) => HubService(
        instanceName: map['instanceName'] as String? ?? 'Eidolon Hub',
        registerUrl: map['registerUrl'] as String? ?? '',
        version: map['version'] as String? ?? '',
        api: map['api'] as String? ?? 'v1',
      );
}

class RoomConfig {
  const RoomConfig({
    required this.serverUrl,
    required this.token,
    required this.identity,
    required this.roomName,
  });

  final String serverUrl;
  final String token;
  final String identity;
  final String roomName;

  bool get usable => serverUrl.isNotEmpty && token.isNotEmpty;

  factory RoomConfig.fromJson(Map<String, dynamic> json) => RoomConfig(
        serverUrl: json['server_url'] as String? ?? '',
        token: json['token'] as String? ?? '',
        identity: json['identity'] as String? ?? '',
        roomName: json['room_name'] as String? ?? '',
      );
}

class HubConfig {
  const HubConfig({
    required this.status,
    required this.active,
    this.control,
    this.registrationId = '',
    this.deviceFingerprint = '',
    this.sampleRate = 16000,
    this.channels = 1,
  });

  final HubConfigStatus status;
  final RoomConfig active;
  final RoomConfig? control;
  final String registrationId;
  final String deviceFingerprint;
  final int sampleRate;
  final int channels;

  factory HubConfig.fromJson(Map<String, dynamic> json) {
    if (json['success'] != true || json['config'] is! Map<String, dynamic>) {
      throw const FormatException('Hub response is missing a valid config');
    }
    final config = json['config'] as Map<String, dynamic>;
    final audio = config['audio'] as Map<String, dynamic>? ?? const {};
    final device = json['device'] as Map<String, dynamic>? ?? const {};
    final control = config['control'];
    return HubConfig(
      status: HubConfigStatus.parse(json['status'] as String?),
      active: RoomConfig.fromJson(config),
      control:
          control is Map<String, dynamic> ? RoomConfig.fromJson(control) : null,
      registrationId: json['registration_id'] as String? ?? '',
      deviceFingerprint: device['fingerprint'] as String? ?? '',
      sampleRate: audio['sample_rate'] as int? ?? 16000,
      channels: audio['channels'] as int? ?? 1,
    );
  }
}

class DeviceIdentity {
  const DeviceIdentity({required this.deviceId, required this.fingerprint});

  final String deviceId;
  final String fingerprint;

  factory DeviceIdentity.fromMap(Map<Object?, Object?> map) => DeviceIdentity(
        deviceId: map['deviceId'] as String? ?? '',
        fingerprint: map['fingerprint'] as String? ?? '',
      );
}

class SignedRequest {
  const SignedRequest({
    required this.deviceId,
    required this.nonce,
    required this.timestamp,
    required this.publicKey,
    required this.signature,
  });

  final String deviceId;
  final String nonce;
  final String timestamp;
  final String publicKey;
  final String signature;

  factory SignedRequest.fromMap(Map<Object?, Object?> map) => SignedRequest(
        deviceId: map['deviceId'] as String? ?? '',
        nonce: map['nonce'] as String? ?? '',
        timestamp: map['timestamp'] as String? ?? '',
        publicKey: map['publicKey'] as String? ?? '',
        signature: map['signature'] as String? ?? '',
      );
}
