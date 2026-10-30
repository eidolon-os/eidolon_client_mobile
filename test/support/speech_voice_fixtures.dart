import 'dart:async';
import 'dart:typed_data';

import 'package:eidolon_client_mobile/src/features/host_setup/voice_recording_player.dart';
import 'package:eidolon_client_mobile/src/features/speech_voice/speech_voice_repository.dart';
import 'package:eidolon_client_mobile/src/features/speech_voice/voice_reference_sources.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';

VoiceOptionView voiceOption(String key, String name,
        {String gender = 'female',
        String ageBand = 'adult',
        bool hostDefault = false,
        bool selectable = true,
        String? summary,
        List<String> styles = const []}) =>
    VoiceOptionView(
        voiceKey: key,
        displayName: name,
        summary: summary,
        gender: gender,
        ageBand: ageBand,
        styleLabels: styles,
        isHostDefault: hostDefault,
        selectable: selectable);

SpeechVoiceCatalogView voiceCatalog(
        {String state = 'fresh',
        bool selectable = true,
        String? notSelectableReason,
        bool design = true,
        bool clone = true,
        List<VoiceOptionView>? voices}) =>
    SpeechVoiceCatalogView(
      catalogRevision: 'r1',
      state: state,
      hostSelectable: selectable,
      notSelectableReason: notSelectableReason,
      voices: voices ??
          [
            voiceOption('c.yang', '龙安洋',
                gender: 'male', hostDefault: true, summary: '阳光大男孩'),
            voiceOption('c.huan', '龙安欢', summary: '欢脱元气女', styles: ['活泼']),
            voiceOption('c.chun', '龙小淳', summary: '知性积极女'),
            voiceOption('c.tong', '龙呼呼', ageBand: 'child'),
          ],
      enrollment:
          VoiceEnrollmentView(design: design, clone: clone, processor: '阿里云百炼'),
      limits: const VoiceLimitsView(
          ownerVoices: 20,
          promptMaxChars: 500,
          previewTextMinChars: 15,
          previewTextMaxChars: 200,
          recordingMinMs: 10000,
          recordingMaxMs: 25000,
          uploadMaxBytes: 10 * 1024 * 1024,
          windowMs: 20000),
    );

CompanionSpeechVoiceView companionVoiceView(
        {String? selected,
        String? selectedName,
        String effective = '龙安洋',
        String? effectiveKey = 'c.yang',
        String reason = 'unset',
        int revision = 1}) =>
    CompanionSpeechVoiceView(
      companionId: 'companion-a',
      revision: revision,
      selectedVoiceKey: selected,
      selectedName: selectedName,
      recordState: 'valid',
      effective: EffectiveVoiceView(
          voiceKey: effectiveKey, displayName: effective, reason: reason),
    );

OwnerVoiceView ownerVoiceView(String id,
        {String name = '小禾的声音',
        String method = 'design',
        String state = 'active',
        String status = 'ready',
        String? statusDetail,
        List<String> usedBy = const [],
        int revision = 1,
        bool hasReference = false}) =>
    OwnerVoiceView(
      voiceKey: 'o.$id',
      voiceAssetId: id,
      name: name,
      method: method,
      state: state,
      revision: revision,
      status: status,
      statusDetail: statusDetail,
      usedBy: usedBy,
      hasReference: hasReference,
      createdAt: '2026-10-31T09:00:00+08:00',
    );

/// The Host, as the voice screens see it: answers set by the test, every call
/// written down.
class FakeSpeechVoices implements SpeechVoices {
  FakeSpeechVoices({
    SpeechVoiceCatalogView? catalog,
    CompanionSpeechVoiceView? current,
    List<OwnerVoiceView> mine = const [],
  })  : catalogAnswer = catalog ?? voiceCatalog(),
        current = current ?? companionVoiceView(),
        mine = [...mine];

  SpeechVoiceCatalogView? catalogAnswer;
  CompanionSpeechVoiceView current;
  List<OwnerVoiceView> mine;
  final calls = <String>[];
  final chosen = <(String?, int)>[];
  final designs = <VoiceDesignBody>[];
  final clones = <VoiceCloneBody>[];
  final changes = <(String, OwnerVoiceChange)>[];
  final deleted = <String>[];
  final checks = <(int, int?)>[];

  /// What [choose] does instead of succeeding, when set.
  Object? chooseFailure;
  ReferenceCheckView Function(Uint8List audio, int? startMs)? checkAnswer;
  OwnerVoiceView Function(VoiceDesignBody body)? designAnswer;

  /// Successive answers to [ownerVoice], to walk a clone through review.
  final reviews = <OwnerVoiceView>[];

  @override
  Future<SpeechVoiceCatalogView> catalog() async {
    calls.add('catalog');
    final answer = catalogAnswer;
    if (answer == null) throw const ManagementRequestException('读取失败');
    return answer;
  }

  @override
  Future<SpeechVoiceCatalogView> refresh() async {
    calls.add('refresh');
    return catalog();
  }

  @override
  Future<Uint8List> preview(String voiceKey, {int sample = 1}) async {
    calls.add('preview $voiceKey');
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<CompanionSpeechVoiceView> companionVoice(String companionId) async {
    calls.add('companion');
    return current;
  }

  @override
  Future<CompanionSpeechVoiceView> choose(
      String companionId, String? voiceKey, int expectedRevision) async {
    chosen.add((voiceKey, expectedRevision));
    final failure = chooseFailure;
    if (failure != null) {
      chooseFailure = null;
      throw failure;
    }
    return current = CompanionSpeechVoiceView(
      companionId: companionId,
      revision: expectedRevision + 1,
      selectedVoiceKey: voiceKey,
      selectedName: voiceKey,
      recordState: 'valid',
      effective: EffectiveVoiceView(
          voiceKey: voiceKey, displayName: '$voiceKey', reason: 'selected'),
    );
  }

  @override
  Future<List<OwnerVoiceView>> ownerVoices() async {
    calls.add('mine');
    return mine;
  }

  @override
  Future<OwnerVoiceView> ownerVoice(String voiceAssetId) async =>
      reviews.length > 1 ? reviews.removeAt(0) : reviews.single;

  @override
  Future<OwnerVoiceView> design(VoiceDesignBody body) async {
    designs.add(body);
    return designAnswer?.call(body) ??
        ownerVoiceView('d${designs.length}', state: 'draft', name: body.name);
  }

  @override
  Future<ReferenceCheckView> check(Uint8List audio, {int? startMs}) async {
    checks.add((audio.length, startMs));
    return checkAnswer?.call(audio, startMs) ??
        ReferenceCheckView(
            accepted: true,
            problems: const [],
            durationMs: 12000,
            windowStartMs: 0,
            windowMs: 12000,
            audioBase64: 'UklGRg==');
  }

  /// The first of [reviews] is what submitting answers; the rest are what each
  /// later look at it finds.
  @override
  Future<OwnerVoiceView> clone(VoiceCloneBody body) async {
    clones.add(body);
    if (reviews.isEmpty) {
      return ownerVoiceView('k1',
          method: 'clone', status: 'preparing', name: body.name);
    }
    return reviews.length > 1 ? reviews.removeAt(0) : reviews.single;
  }

  @override
  Future<OwnerVoiceView> change(
      String voiceAssetId, OwnerVoiceChange change) async {
    changes.add((voiceAssetId, change));
    return ownerVoiceView(voiceAssetId,
        name: change.name ?? '小禾的声音',
        revision: change.expectedRevision + 1,
        hasReference: change.dropReference != true);
  }

  @override
  Future<void> delete(OwnerVoiceView voice) async {
    deleted.add(voice.voiceAssetId);
    mine.removeWhere((v) => v.voiceAssetId == voice.voiceAssetId);
  }
}

class SilentPlayer implements VoiceRecordingPlayer {
  final _done = StreamController<void>.broadcast();
  final played = <Uint8List>[];

  @override
  Stream<void> get completed => _done.stream;
  @override
  Future<void> play(Uint8List pcm) async => played.add(pcm);
  @override
  Future<void> playWav(Uint8List wav) async => played.add(wav);
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() => _done.close();
}

/// A microphone the test speaks into: [speak] pushes that many milliseconds of
/// a steady tone.
class ScriptedRecorder implements ReferenceRecorder {
  bool permitted = true, stopped = false;
  StreamController<Uint8List>? _stream;

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<Stream<Uint8List>> start() async {
    stopped = false;
    return (_stream = StreamController<Uint8List>()).stream;
  }

  void speak(int ms) {
    final bytes = Uint8List(ms * referenceSampleRate * 2 ~/ 1000);
    final samples = ByteData.sublistView(bytes);
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      samples.setInt16(i, i % 200 < 100 ? 8000 : -8000, Endian.little);
    }
    _stream!.add(bytes);
  }

  @override
  Future<void> stop() async {
    stopped = true;
    // Not awaited: the page has already cancelled its subscription.
    unawaited(_stream?.close());
  }

  @override
  Future<void> dispose() async {}
}

class GivenFile implements AudioFilePicker {
  GivenFile(this.file);
  final PickedAudio? file;
  @override
  Future<PickedAudio?> pick() async => file;
}
