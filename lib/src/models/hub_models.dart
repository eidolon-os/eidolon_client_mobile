import '../features/conversation/mobile_body_standing.dart';
import '../features/device_setup/device_instance_identity.dart';
import '../features/conversation/channel_refusal.dart';

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

/// What this client was granted: one channel it holds for as long as it is
/// enrolled. It used to be two — a control room it lived in and a voice room it
/// visited — and whether anyone was listening was read from which one it stood
/// in. The channel no longer moves, so the client says so instead.
class HubConfig {
  const HubConfig({
    required this.status,
    required this.session,
    this.registrationId = '',
    this.deviceFingerprint = '',
    this.bodyStanding,
    this.bodyEnrollment,
    this.channelRefusal,
    this.diagnostic = '',
  });

  /// Why there is no channel, when Device Control refused to say.
  ///
  /// Null when nothing was refused — including the ordinary case where the
  /// Host answered and simply had no channel yet. See [ChannelRefusal] for why
  /// this is its own field rather than more [bodyStanding] values.
  final ChannelRefusal? channelRefusal;
  final String diagnostic;

  final HubConfigStatus status;
  final RoomConfig session;
  final String registrationId;
  final String deviceFingerprint;

  /// Where this phone stands as a Body, when the answer came from Admission.
  ///
  /// Null on the legacy Hub register path, which never knew this. The five
  /// [HubConfigStatus] values cannot carry it: three distinct Admission stages
  /// map onto `waitingBinding` alone, and "this phone has no Enrollment at all"
  /// mapped onto `pendingApproval` — which is how the screen came to announce
  /// that the Host was claiming a device it had never heard of.
  final MobileBodyStanding? bodyStanding;

  /// The Enrollment behind [bodyStanding], when there is one.
  ///
  /// Null whenever no proposal exists — which is not the same as "there is one
  /// and this build could not read it". The stages differ in what a person can
  /// do, so the absence has to be the absence rather than a default.
  final MobileBodyEnrollmentRef? bodyEnrollment;

  factory HubConfig.fromJson(Map<String, dynamic> json) {
    if (json['success'] != true || json['config'] is! Map<String, dynamic>) {
      throw const FormatException('Hub response is missing a valid config');
    }
    final config = json['config'] as Map<String, dynamic>;
    final device = json['device'] as Map<String, dynamic>? ?? const {};
    return HubConfig(
      status: HubConfigStatus.parse(json['status'] as String?),
      session: RoomConfig.fromJson(config),
      registrationId: json['registration_id'] as String? ?? '',
      deviceFingerprint: device['fingerprint'] as String? ?? '',
    );
  }
}

class DeviceIdentity {
  const DeviceIdentity({
    required this.installId,
    required this.operationalPublicKey,
    required this.fingerprint,
  });

  /// What ANDROID_ID can name: this installation on this Android user.
  ///
  /// Not this device's identity to Hub, and deliberately no longer called
  /// `deviceId`. It named nothing Hub had ever heard of — Hub derives a device
  /// instance id from the operational key and answers 422 to anything else —
  /// while every screen and every comparison in this app read it as the
  /// device's identity.
  final String installId;

  /// The operational key as it appears on the wire, `p256-spki:<base64url>`.
  final String operationalPublicKey;

  final String fingerprint;

  /// This device's identity in the Owner Domain, derived from its own key.
  String get deviceInstanceId => deriveDeviceInstanceId(operationalPublicKey);

  factory DeviceIdentity.fromMap(Map<Object?, Object?> map) => DeviceIdentity(
        installId: map['installId'] as String? ?? '',
        operationalPublicKey: map['operationalPublicKey'] as String? ?? '',
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
