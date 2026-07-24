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

  group('shouldShowAvatarVideo', () {
    test('shows the live talking-head only while speaking with a track', () {
      expect(
        shouldShowAvatarVideo(
            hasVideoTrack: true, turn: AgentTurnState.speaking),
        isTrue,
      );
    });

    test('hides video at idle/listening/thinking even when a track exists', () {
      for (final turn in [
        AgentTurnState.idle,
        AgentTurnState.listening,
        AgentTurnState.thinking,
      ]) {
        expect(
          shouldShowAvatarVideo(hasVideoTrack: true, turn: turn),
          isFalse,
          reason: 'turn=$turn should keep the local placeholder',
        );
      }
    });

    test('hides video while speaking before the track arrives', () {
      expect(
        shouldShowAvatarVideo(
            hasVideoTrack: false, turn: AgentTurnState.speaking),
        isFalse,
      );
    });
  });
}
