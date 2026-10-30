import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';

/// Where the recording a clone is made from comes from: the microphone, or an
/// audio file the person already has. Ports, so the clone screen is testable
/// without either.
abstract interface class ReferenceRecorder {
  Future<bool> hasPermission();

  /// Mono PCM16 at [referenceSampleRate], as it is captured.
  Future<Stream<Uint8List>> start();
  Future<void> stop();
  Future<void> dispose();
}

/// What the Host keeps from a clone recording; recording at it means nothing is
/// resampled before the Host measures it.
const referenceSampleRate = 24000;

/// Records on the phone itself. Unlike a voiceprint, a clone reference is about
/// the voice and not about how the Host hears it through a device, so it does
/// not travel through a conversation room first.
class MicrophoneReferenceRecorder implements ReferenceRecorder {
  final _recorder = AudioRecorder();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: referenceSampleRate,
      numChannels: 1,
      // The Host checks loudness and clipping itself; a gain stage here would
      // hide both from it.
      autoGain: false));

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

class PickedAudio {
  const PickedAudio(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

abstract interface class AudioFilePicker {
  /// The chosen file, or null when the person changed their mind.
  Future<PickedAudio?> pick();
}

class SystemAudioFilePicker implements AudioFilePicker {
  const SystemAudioFilePicker();

  /// What the Host decodes. Others may well decode too, but a person should not
  /// be offered a file the Host is only likely to read.
  static const extensions = ['wav', 'mp3', 'm4a', 'aac', 'flac'];

  @override
  Future<PickedAudio?> pick() async {
    final file = await FilePicker.pickFile(
        type: FileType.custom, allowedExtensions: extensions);
    if (file == null) return null;
    return PickedAudio(file.name, await file.readAsBytes());
  }
}
