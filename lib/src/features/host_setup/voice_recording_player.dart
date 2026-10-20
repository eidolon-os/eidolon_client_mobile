import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';

/// Playback only. Authentication and owner-scoped retrieval stay in Management.
abstract interface class VoiceRecordingPlayer {
  Stream<void> get completed;
  Future<void> play(Uint8List pcm);
  Future<void> stop();
  Future<void> dispose();
}

class LocalVoiceRecordingPlayer implements VoiceRecordingPlayer {
  final AudioPlayer _player = AudioPlayer();
  Directory? _temporary;
  bool _disposed = false;
  @override
  Stream<void> get completed => _player.onPlayerComplete;
  @override
  Future<void> play(Uint8List pcm) async {
    if (_disposed) return;
    final wav = voiceRecordingWav(pcm);
    // audioplayers writes BytesSource to an unmanaged file on Apple platforms.
    // Own that file explicitly so closing playback also removes the recording.
    if (!kIsWeb && (Platform.isIOS || Platform.isMacOS || Platform.isLinux)) {
      final directory = _temporary ??=
          await Directory.systemTemp.createTemp('voice-playback-');
      final file = File('${directory.path}/recording.wav');
      try {
        if (_disposed) return;
        await file.writeAsBytes(wav, flush: true);
        if (!_disposed) {
          await _player
              .play(DeviceFileSource(file.path, mimeType: 'audio/wav'));
        }
      } finally {
        if (_disposed && await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    } else if (!_disposed) {
      await _player.play(BytesSource(wav, mimeType: 'audio/wav'));
    }
  }

  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> dispose() async {
    _disposed = true;
    try {
      await _player.dispose();
    } finally {
      final directory = _temporary;
      if (directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
      _temporary = null;
    }
  }
}

/// The management recording contract is always mono, little-endian PCM16/16kHz.
Uint8List voiceRecordingWav(Uint8List pcm) {
  if (pcm.length.isOdd || pcm.length < 48000 || pcm.length > 960000) {
    throw const FormatException('Invalid voice recording');
  }
  final bytes = Uint8List(44 + pcm.length);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'RIFF');
  data.setUint32(4, 36 + pcm.length, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, pcm.length, Endian.little);
  bytes.setRange(44, bytes.length, pcm);
  return bytes;
}
