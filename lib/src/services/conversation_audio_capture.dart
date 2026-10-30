import 'package:livekit_client/livekit_client.dart';

/// One capture policy for conversation, voice enrollment and match verification.
const conversationAudioCapture = AudioCaptureOptions(
  echoCancellation: true,
  noiseSuppression: true,
  autoGainControl: true,
  voiceIsolation: true,
  typingNoiseDetection: true,
  stopAudioCaptureOnMute: false,
);
