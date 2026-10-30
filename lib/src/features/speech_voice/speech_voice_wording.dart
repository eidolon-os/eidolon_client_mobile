import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import '../host_setup/failure_sentences.dart';

/// The Host's voice is standing in: nothing chosen, or what was chosen
/// cannot be used here right now.
const _standIns = {
  'unset',
  'host_fixed_voice',
  'invalid_record',
  'no_equivalent',
  'owner_voice_pending',
  'owner_voice_rejected',
  'owner_voice_unavailable',
  'authority_unavailable',
  'catalog_unavailable',
};

/// Where the voice in use comes from.
String voiceSource(CompanionSpeechVoiceView view) {
  final reason = view.effective?.reason;
  if (reason == 'owner_voice') return '我的声音';
  if (_standIns.contains(reason)) return '主机默认';
  return '系统声音';
}

/// Why the voice in use is not simply the one chosen (§5.2, §17.8), or null
/// when it is.
String? voiceCaveat(CompanionSpeechVoiceView view,
    {SpeechVoiceCatalogView? catalog}) {
  final chosen = view.selectedName ?? '选的声音';
  return switch (view.effective?.reason) {
    'host_fixed_voice' => catalog?.notSelectableReason == 'single_voice'
        ? '这台主机目前只有一个可用的声音'
        : '这台主机暂不支持更换声音',
    'invalid_record' => '声音设置无法读取，正在用主机默认',
    'mapped' => '相近声音',
    'no_equivalent' => '这台主机没有相近的声音，正在用主机默认',
    'owner_voice_pending' => '「$chosen」正在准备，暂用主机默认',
    'owner_voice_rejected' => '「$chosen」没能生成，正在用主机默认',
    'owner_voice_unavailable' => '「$chosen」在这台主机上暂时不能用，正在用主机默认',
    'authority_unavailable' || 'catalog_unavailable' => '暂时确认不了，先用主机默认',
    _ => null,
  };
}

/// The sentence under 「声音」: which voice it will speak in next time, and why
/// when that is not simply the one chosen.
///
/// Built from the Host's own answer, so the phone and the voice worker never
/// tell two stories. Null when the Host could not confirm right now.
String? voiceLine(CompanionSpeechVoiceView view,
    {SpeechVoiceCatalogView? catalog}) {
  final effective = view.effective;
  if (effective == null) return null;
  final name = effective.displayName;
  if (effective.reason == 'mapped') return '相近声音 · $name';
  return voiceCaveat(view, catalog: catalog) ??
      switch (voiceSource(view)) {
        '系统声音' => name,
        final source => '$source · $name',
      };
}

/// Which shelf a Host voice sits on.
String voiceShelf(VoiceOptionView voice) {
  if (voice.ageBand == 'child') return '童声';
  if (voice.ageBand == 'senior') return '长者';
  if (voice.gender == 'female') return '女声';
  if (voice.gender == 'male') return '男声';
  return '其他';
}

const voiceShelves = ['女声', '男声', '童声', '长者', '其他'];

String voiceMethod(String method) => method == 'clone' ? '录音复刻' : '文字设计';

/// How one of the Owner's voices stands on this Host's current voice model.
String ownerVoiceStatus(OwnerVoiceView voice) {
  if (voice.state == 'draft') return '未保存';
  switch (voice.status) {
    case 'ready':
      return '可用';
    case 'preparing':
      return '正在准备';
    case 'rejected':
      return '没能生成';
  }
  return '这台主机暂时不能用';
}

/// What went wrong with a recording, in words a person can act on.
String referenceProblem(String code) => switch (code) {
      'unreadable' => '读不出这段音频，请换一个文件',
      'too_large' => '文件太大，请选择 10 MB 以内的文件',
      'too_short' => '太短了，请录满 10 秒',
      'too_long' => '太长了，请选择 60 秒以内的音频',
      'too_little_speech' => '说话时间不足 5 秒',
      'too_quiet' => '声音太小，请靠近一些',
      'clipping' => '有爆音，请离远一点或小声一些',
      _ => '这段录音不能用',
    };

/// 「N 个伙伴在用」, or null when none is.
String? usedByLine(OwnerVoiceView voice) =>
    voice.usedBy.isEmpty ? null : '${voice.usedBy.length} 个伙伴在用';

/// A refusal in the Host's own words: the voice routes write theirs for the
/// person holding the phone. Anything else goes through the app's one sentence
/// for an ungraded failure.
String voiceFailure(Object error) => error is ManagementRequestException
    ? error.reason ?? error.message
    : failureSentence(error);
