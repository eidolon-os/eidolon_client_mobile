import 'package:eidolon_client_mobile/src/avatar/avatar_stage.dart';
import 'package:eidolon_client_mobile/src/models/client_ui_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isAvatarIdentity', () {
    test('matches only the avatar- worker identity', () {
      expect(isAvatarIdentity('avatar-device-abc-1234'), isTrue);
      expect(isAvatarIdentity('agent-xyz'), isFalse);
      expect(isAvatarIdentity('manson-web'), isFalse);
      expect(isAvatarIdentity(''), isFalse);
    });
  });

  group('companionIdleUrl', () {
    test('derives the idle path from the hub register origin', () {
      expect(
        companionIdleUrl(
            'http://192.168.1.10:8082/api/device/register?agent_mode=streaming'),
        'http://192.168.1.10:8082/api/avatar/idle/video',
      );
      expect(
        companionIdleUrl('https://hub.local:8443/api/device/register'),
        'https://hub.local:8443/api/avatar/idle/video',
      );
    });

    test('returns null for an unparseable register url', () {
      expect(companionIdleUrl(''), isNull);
      expect(companionIdleUrl('not a url'), isNull);
    });
  });

  group('isAvatarVideoActive', () {
    test('active while speaking or thinking (kept through thinking gaps)', () {
      expect(
        isAvatarVideoActive(hasVideoTrack: true, turn: AgentTurnState.speaking),
        isTrue,
      );
      expect(
        isAvatarVideoActive(hasVideoTrack: true, turn: AgentTurnState.thinking),
        isTrue,
      );
    });

    test('inactive at idle/listening (a sustained pause → idle loop)', () {
      for (final turn in [AgentTurnState.idle, AgentTurnState.listening]) {
        expect(
          isAvatarVideoActive(hasVideoTrack: true, turn: turn),
          isFalse,
          reason: 'turn=$turn should (after the hold) fall back to idle',
        );
      }
    });

    test('inactive without a track regardless of turn', () {
      expect(
        isAvatarVideoActive(
            hasVideoTrack: false, turn: AgentTurnState.speaking),
        isFalse,
      );
    });
  });
}
