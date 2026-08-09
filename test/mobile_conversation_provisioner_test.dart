import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/conversation/hub_onboarding_client.dart';
import 'package:eidolon_client_mobile/src/features/conversation/hub_onboarding_models.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_security.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/platform/platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _fingerprint =
    'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8';
const _enrollmentId = 'enrollment_abcdefghijklmnopqrstuvwx';
const _pairingSecret = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFG';
const _retrievalToken = 'retrieval-token-abcdefghijklmnopqrstuvwxyz';

void main() {
  test('provisions Mobile through Owner claim and consumes Provider binding',
      () async {
    final expectedRevision = await canonicalManifestRevision(
      mobileBodyManifest,
    );
    final security = _Security();
    final requests = <http.Request>[];
    final hubClient = _hubClient(
      security,
      requests,
      handoffResponse: _handoffResponse(expectedRevision),
    );
    DevicePairingPayload? claimedPairing;
    String? claimedSetupId;
    String? claimedRequestId;
    final provisioner = MobileConversationProvisioner(
      loadTarget: () async => _target,
      claimAdmission: ({
        required setupId,
        required requestId,
        required pairing,
      }) async {
        claimedPairing = pairing;
        claimedSetupId = setupId;
        claimedRequestId = requestId;
        return DeviceAdmissionProgress(
          setupId: setupId,
          requestId: requestId,
          deviceId: 'mobile-android-test',
          enrollmentId: pairing.enrollmentId,
          ownerId: 'owner-1',
          state: DeviceAdmissionState.ready,
          completedStage: 'companion-attached',
          companionId: 'companion-1',
        );
      },
      platform: _Platform(),
      security: security,
      hubClient: hubClient,
      clock: () => DateTime.utc(2026, 8, 9),
    );

    final config = await provisioner.provision();

    expect(config.status, HubConfigStatus.active);
    expect(config.registrationId, 'channel-mobile-1');
    expect(config.active.roomName, 'mobile-voice');
    expect(config.control?.roomName, 'mobile-control');
    expect(config.sampleRate, 16000);
    expect(config.channels, 1);
    expect(claimedPairing?.enrollmentId, _enrollmentId);
    expect(claimedPairing?.pairingSecret, _pairingSecret);
    expect(claimedSetupId, startsWith('mobile-body-'));
    expect(claimedRequestId, startsWith('mobile-body-claim-'));
    expect(security.pairingSecretCleared, isTrue);
    expect(
      requests.map((request) => '${request.method} ${request.url.path}'),
      [
        'GET /api/device-onboarding/v1/descriptor',
        'POST /api/device-onboarding/v1/enrollments',
        'POST /api/device-onboarding/v1/enrollments/$_enrollmentId/handoff',
      ],
    );
  });

  test('does not request Provider binding before Local admission is ready',
      () async {
    final security = _Security();
    final requests = <http.Request>[];
    final provisioner = MobileConversationProvisioner(
      loadTarget: () async => _target,
      claimAdmission: ({
        required setupId,
        required requestId,
        required pairing,
      }) async =>
          DeviceAdmissionProgress(
        setupId: setupId,
        requestId: requestId,
        deviceId: 'mobile-android-test',
        enrollmentId: pairing.enrollmentId,
        ownerId: 'owner-1',
        state: DeviceAdmissionState.binding,
        completedStage: 'kernel-mounted',
        companionId: 'companion-1',
      ),
      platform: _Platform(),
      security: security,
      hubClient: _hubClient(
        security,
        requests,
        handoffResponse: http.Response('must not hand off', 500),
      ),
      clock: () => DateTime.utc(2026, 8, 9),
    );

    final config = await provisioner.provision();

    expect(config.status, HubConfigStatus.waitingBinding);
    expect(security.pairingSecretCleared, isFalse);
    expect(requests, hasLength(2));
  });
}

HubOnboardingClient _hubClient(
  _Security security,
  List<http.Request> requests, {
  required http.Response handoffResponse,
}) =>
    HubOnboardingClient(
      security: security,
      clientFactory: (fingerprint) {
        expect(fingerprint, _fingerprint);
        return MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            return http.Response(jsonEncode(_descriptor), 200);
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['operation'] == 'device.enrollment') {
            return http.Response(
              jsonEncode({
                'operation': 'device.enrollment-received',
                'request_id': 'mobile-enroll-1',
                'enrollment_id': _enrollmentId,
                'device_id': 'mobile-android-test',
                'lifecycle_state': 'pending-approval',
                'retrieval_expires_at_ms': 1893456000000,
                'pairing_claim_uri':
                    'https://eidolon.example/api/device-management/v1/'
                        'enrollments/$_enrollmentId/pairing-claims',
              }),
              200,
            );
          }
          return handoffResponse;
        });
      },
    );

http.Response _handoffResponse(String manifestRevision) {
  final binding = utf8.encode(
    jsonEncode({
      'schema_version': 1,
      'active': {
        'server_url': 'wss://livekit.example',
        'token': 'voice-token',
        'identity': 'mobile-android-test',
        'room_name': 'mobile-voice',
      },
      'control': {
        'server_url': 'wss://livekit.example',
        'token': 'control-token',
        'identity': 'mobile-android-test',
        'room_name': 'mobile-control',
      },
      'audio': {'sample_rate': 16000, 'channels': 1},
    }),
  );
  return http.Response(
    jsonEncode({
      'operation': 'device.handoff-outcome',
      'request_id': 'mobile-handoff-1',
      'enrollment_id': _enrollmentId,
      'device_id': 'mobile-android-test',
      'manifest_revision': manifestRevision,
      'lifecycle_state': 'approved',
      'channels': [
        {
          'channel_id': 'channel-mobile-1',
          'purpose': 'voice',
          'kinds': ['reliable-data', 'audio', 'video'],
          'binding_format': mobileLiveKitBindingFormat,
          'issued_at_ms': 1786240000000,
          'expires_at_ms': 1893456000000,
          'opaque_binding': base64Encode(binding),
        },
      ],
    }),
    200,
  );
}

final _target = DeviceOnboardingTarget(
  hubId: 'hub-local',
  descriptorUri: Uri.parse(
    'https://eidolon.example/api/device-onboarding/v1/descriptor',
  ),
  tlsSpkiFingerprint: _fingerprint,
);

const _descriptor = {
  'schema_version': 1,
  'hub_id': 'hub-local',
  'descriptor_uri':
      'https://eidolon.example/api/device-onboarding/v1/descriptor',
  'device_onboarding_uri': 'https://eidolon.example/api/device-onboarding/v1',
  'enrollment_uri':
      'https://eidolon.example/api/device-onboarding/v1/enrollments',
  'protocol_versions': [1],
};

class _Platform extends PlatformBridge {
  @override
  Future<DeviceIdentity> getDeviceIdentity() async => const DeviceIdentity(
        deviceId: 'mobile-android-test',
        fingerprint: 'p256:mobile-test',
      );
}

class _Security implements MobileBodySecurity {
  var pairingSecretCleared = false;

  @override
  Future<DeviceEnrollmentMaterial> loadOrCreateMaterial(String hubId) async =>
      const DeviceEnrollmentMaterial(
        enrollmentRequestId: 'mobile-enroll-1',
        handoffRequestId: 'mobile-handoff-1',
        retrievalToken: _retrievalToken,
        pairingSecret: _pairingSecret,
      );

  @override
  Future<void> clearMaterial(String hubId) async {}

  @override
  Future<void> clearPairingSecret(String hubId) async {
    pairingSecretCleared = true;
  }

  @override
  Future<void> saveEnrollmentReceipt({
    required String hubId,
    required String enrollmentId,
    required DateTime retrievalExpiresAt,
  }) async {}

  @override
  Future<DeviceEnrollmentIdentityProof> signEnrollmentProof({
    required String requestId,
    required String deviceId,
    required String retrievalTokenHash,
    required String pairingMethod,
    required String pairingCommitment,
    required String deviceKind,
    required String displayName,
    required String manifestRevision,
  }) async =>
      DeviceEnrollmentIdentityProof(
        publicKeySpki: List.filled(80, 'A').join(),
        signature: List.filled(64, 'B').join(),
      );
}
