import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:livekit_client/livekit_client.dart';
import 'package:record/record.dart';
import '../../services/conversation_audio_capture.dart';
import '../../generated/management_v1.dart';
import 'voiceprint_call.dart';

abstract interface class VoiceEnrollmentRecorder {
  Future<bool> hasPermission();
  Future<Stream<Uint8List>> start();

  /// Final server-decoded PCM, or null for an incremental recorder.
  Future<Uint8List?> stop();
  Future<void> cancel();
  Future<void> dispose();
}

/// Publishes with the same microphone options as conversation. The Host returns
/// its decoded PCM, so enrollment includes the actual media transport path.
class LiveKitVoiceEnrollmentRecorder implements VoiceEnrollmentRecorder {
  LiveKitVoiceEnrollmentRecorder(this.call);
  final VoiceprintCall call;
  int _generation = 0;
  Room? _room;
  String? _captureId;
  StreamController<Uint8List>? _stream;

  @override
  Future<bool> hasPermission() async {
    // Reuse the existing permission request; never open a second microphone.
    final permission = AudioRecorder();
    try {
      return await permission.hasPermission();
    } finally {
      await permission.dispose();
    }
  }

  @override
  Future<Stream<Uint8List>> start() async {
    await cancel();
    final generation = _generation;
    try {
      final capture = VoiceCaptureSession.fromJson(
          await call(method: 'POST', suffix: '/captures'));
      final id = capture.captureId;
      if (generation != _generation) {
        await call(method: 'DELETE', suffix: '/captures/$id');
        throw StateError('录音准备已中断');
      }
      _captureId = id;
      final urls = capture.serverUrls;
      for (final url in urls) {
        final room = Room(
            roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultAudioCaptureOptions: conversationAudioCapture,
        ));
        _room = room;
        try {
          await room.connect(url, capture.token);
          if (generation != _generation) throw StateError('录音准备已中断');
          await room.localParticipant!.setMicrophoneEnabled(true);
          if (generation != _generation) throw StateError('录音准备已中断');
          _stream = StreamController<Uint8List>();
          return _stream!.stream;
        } catch (_) {
          await room.disconnect();
          await room.dispose();
          _room = null;
          if (generation != _generation) rethrow;
        }
      }
      throw StateError('无法连接主机录音，请检查网络');
    } catch (_) {
      await cancel();
      rethrow;
    }
  }

  @override
  Future<Uint8List?> stop() async {
    final id = _captureId;
    if (id == null) throw StateError('录音已结束，请重新开始');
    try {
      await _room?.localParticipant?.setMicrophoneEnabled(false);
      final result = await call(method: 'POST', suffix: '/captures/$id/finish');
      return base64Decode(VoiceAudioRequest.fromJson(result).pcmBase64);
    } finally {
      await cancel();
    }
  }

  @override
  Future<void> cancel() async {
    _generation++;
    final id = _captureId;
    _captureId = null;
    final room = _room;
    _room = null;
    if (room != null) {
      await room.disconnect();
      await room.dispose();
    }
    // Do not wait on a stream with no subscriber (start may be cancelled).
    final stream = _stream;
    _stream = null;
    if (stream != null) unawaited(stream.close());
    if (id != null) {
      try {
        await call(method: 'DELETE', suffix: '/captures/$id');
      } catch (_) {
        // Successful finish consumes it; otherwise the Host expires it in 45 s.
      }
    }
  }

  @override
  Future<void> dispose() => cancel();
}
