import 'package:eidolon_client_mobile/src/features/speech_voice/speech_voice_wording.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/speech_voice_fixtures.dart';

/// The line under 「声音」 for every answer the Host can give (§5.2, §17.8), and
/// the head of the voice page, which must not repeat the name it shows.
void main() {
  String? line(String reason,
          {String effective = '龙安洋', String? chosen, String? notSelectable}) =>
      voiceLine(
          companionVoiceView(
              reason: reason, effective: effective, selectedName: chosen),
          catalog: notSelectable == null
              ? null
              : voiceCatalog(
                  selectable: false, notSelectableReason: notSelectable));

  test('each resolution reads as the design says', () {
    expect(line('unset'), '主机默认 · 龙安洋');
    expect(line('selected', effective: '龙安欢'), '龙安欢');
    expect(line('same_voice_other_model', effective: '龙安欢'), '龙安欢');
    expect(line('mapped', effective: '龙小淳'), '相近声音 · 龙小淳');
    expect(line('no_equivalent'), '这台主机没有相近的声音，正在用主机默认');
    expect(line('invalid_record'), '声音设置无法读取，正在用主机默认');
    expect(line('host_fixed_voice', notSelectable: 'single_voice'),
        '这台主机目前只有一个可用的声音');
    expect(
        line('host_fixed_voice', notSelectable: 'no_adapter'), '这台主机暂不支持更换声音');
    expect(line('owner_voice', effective: '小禾的声音'), '我的声音 · 小禾的声音');
    expect(line('owner_voice_pending', chosen: '小禾的声音'), '「小禾的声音」正在准备，暂用主机默认');
    expect(
        line('owner_voice_rejected', chosen: '小禾的声音'), '「小禾的声音」没能生成，正在用主机默认');
    expect(line('owner_voice_unavailable', chosen: '小禾的声音'),
        '「小禾的声音」在这台主机上暂时不能用，正在用主机默认');
  });

  test('a reason this build has not heard of still names the voice', () {
    expect(line('something_new', effective: '龙安欢'), '龙安欢');
  });

  test('the page head says where the voice comes from, never the name again',
      () {
    String head(String reason, {String? chosen}) {
      final view = companionVoiceView(reason: reason, selectedName: chosen);
      return voiceCaveat(view) ?? voiceSource(view);
    }

    expect(head('owner_voice'), '我的声音');
    expect(head('selected'), '系统声音');
    expect(head('unset'), '主机默认');
    expect(head('owner_voice_pending', chosen: '阿福'), '「阿福」正在准备，暂用主机默认');
  });
}
