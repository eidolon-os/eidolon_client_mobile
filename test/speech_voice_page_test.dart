import 'package:eidolon_client_mobile/src/features/speech_voice/speech_voice_page.dart';
import 'package:eidolon_client_mobile/src/features/speech_voice/speech_voice_tile.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/speech_voice_fixtures.dart';

/// The voice page says what the Host resolved, offers what the Host can do,
/// and saves a choice the way every other revisioned write does.

Future<SilentPlayer> _open(WidgetTester tester, FakeSpeechVoices voices) async {
  final player = SilentPlayer();
  await tester.pumpWidget(MaterialApp(
    home: SpeechVoicePage(
      companionId: 'companion-a',
      companionName: '小禾',
      voices: voices,
      companionNames: const {'companion-a': '小禾', 'companion-b': '阿福'},
      playerFactory: () => player,
    ),
  ));
  await tester.pumpAndSettle();
  return player;
}

/// Scrolls the page until [finder] is on screen, then taps it.
Future<void> _reach(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200,
      scrollable: find.byType(Scrollable).last);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the head says what it will use next time, and why',
      (tester) async {
    await _open(tester, FakeSpeechVoices());

    expect(find.text('下次对话会用'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('voice-head-line'))).data,
        '主机默认');
    // Not choosing is following the Host, and the list says so.
    expect(
        find.descendant(
            of: find.byKey(const Key('voice-host-default')),
            matching: find.byIcon(Icons.check_circle)),
        findsOneWidget);
    // Grouped the way a person looks for a voice; the Host default is not
    // listed twice.
    expect(find.text('女声'), findsOneWidget);
    expect(find.text('童声'), findsOneWidget);
    expect(find.text('男声'), findsNothing);
  });

  testWidgets('choosing saves against the revision read, then says when',
      (tester) async {
    final voices = FakeSpeechVoices();
    await _open(tester, voices);

    await tester.tap(find.text('龙安欢'));
    await tester.pumpAndSettle();

    expect(voices.chosen, [('c.huan', 1)]);
    expect(find.text('下次和小禾对话时生效'), findsOneWidget);

    // And back to the Host's own voice, which is no key at all.
    await tester.tap(find.byKey(const Key('voice-host-default')));
    await tester.pumpAndSettle();
    expect(voices.chosen.last, (null, 2));
  });

  testWidgets('someone else changing it first rereads instead of overwriting',
      (tester) async {
    final voices = FakeSpeechVoices()
      ..chooseFailure = const ManagementRequestException('换声音被拒绝',
          statusCode: 409, refusal: Refusal(kind: 'conflict'));
    await _open(tester, voices);
    final reads = voices.calls.where((c) => c == 'companion').length;

    await tester.tap(find.text('龙安欢'));
    await tester.pumpAndSettle();

    expect(voices.calls.where((c) => c == 'companion').length, reads + 1);
    expect(find.text('这个伙伴的声音刚被改过，已经重新读取'), findsOneWidget);
  });

  testWidgets('a voice standing in for the chosen one can be adopted',
      (tester) async {
    final voices = FakeSpeechVoices(
        current: companionVoiceView(
            selected: 'c.gone',
            selectedName: '龙安温',
            effective: '龙小淳',
            effectiveKey: 'c.chun',
            reason: 'mapped'));
    await _open(tester, voices);

    expect(find.text('你选的「龙安温」在这台主机上不可用，正在用相近的「龙小淳」。'), findsOneWidget);
    await tester.tap(find.text('就用龙小淳'));
    await tester.pumpAndSettle();

    expect(voices.chosen, [('c.chun', 1)]);
  });

  testWidgets('a Host that cannot offer a choice says why and stays usable',
      (tester) async {
    final voices = FakeSpeechVoices(
        catalog: voiceCatalog(
            selectable: false, notSelectableReason: 'single_voice'),
        current: companionVoiceView(reason: 'host_fixed_voice'));
    await _open(tester, voices);

    expect(find.text('这台主机目前只有一个可用的声音。'), findsOneWidget);
    expect(find.text('龙安欢'), findsNothing);
    // The one voice there is can still be heard.
    expect(find.byKey(const Key('audition-c.yang')), findsWidgets);
  });

  testWidgets('without a catalog only the Host voice is offered, with a retry',
      (tester) async {
    final voices = FakeSpeechVoices()..catalogAnswer = null;
    await _open(tester, voices);

    expect(find.byKey(const Key('voice-catalog-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('voice-host-default')), findsOneWidget);
    expect(find.text('龙安欢'), findsNothing);

    voices.catalogAnswer = voiceCatalog();
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(voices.calls, contains('refresh'));
    expect(find.text('龙安欢'), findsOneWidget);
  });

  testWidgets('a stale list says so', (tester) async {
    await _open(
        tester, FakeSpeechVoices(catalog: voiceCatalog(state: 'stale')));
    expect(find.text('列表可能不是最新，下拉可以刷新。'), findsOneWidget);
  });

  testWidgets('a preview plays without leaving the page', (tester) async {
    final voices = FakeSpeechVoices();
    final player = await _open(tester, voices);

    await tester.tap(find.byKey(const Key('audition-c.huan')));
    await tester.pumpAndSettle();

    expect(voices.calls, contains('preview c.huan'));
    expect(player.played, hasLength(1));
  });

  testWidgets('a sample the phone cannot play is said, and the ▶ comes back',
      (tester) async {
    final player = await _open(tester, FakeSpeechVoices());

    await tester.tap(find.byKey(const Key('audition-c.huan')));
    await tester.pump();
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
    player.failToOpen();
    await tester.pump();
    await tester.pump();

    expect(find.text('暂时听不了这个声音，请稍后再试'), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
  });

  testWidgets('my voices: what each is, who uses it, and choosing one',
      (tester) async {
    final voices = FakeSpeechVoices(mine: [
      ownerVoiceView('v1', usedBy: ['companion-b']),
      ownerVoiceView('v2', name: '妈妈的声音', method: 'clone', status: 'preparing'),
      ownerVoiceView('d1', state: 'draft'),
    ]);
    await _open(tester, voices);

    await tester.tap(find.text('我的声音'));
    await tester.pumpAndSettle();

    expect(find.text('文字设计 · 可用 · 1 个伙伴在用'), findsOneWidget);
    expect(find.text('录音复刻 · 正在准备'), findsOneWidget);
    // A draft is the design screen's business, not the library's.
    expect(find.byKey(const Key('owner-voice-d1')), findsNothing);

    voices.mine = [
      ownerVoiceView('v1'),
      ownerVoiceView('v2',
          name: '妈妈的声音',
          method: 'clone',
          status: 'preparing',
          usedBy: ['companion-a']),
    ];
    await tester.tap(find.text('妈妈的声音'));
    await tester.pumpAndSettle();
    expect(voices.chosen, [('o.v2', 1)]);
    // Who uses which voice moved with the choice, and the list says so.
    expect(find.text('文字设计 · 可用'), findsOneWidget);
    expect(find.text('录音复刻 · 正在准备 · 1 个伙伴在用'), findsOneWidget);
  });

  testWidgets('an empty library explains both ways to make a voice',
      (tester) async {
    await _open(tester, FakeSpeechVoices());
    await tester.tap(find.text('我的声音'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('owner-voices-empty')), findsOneWidget);
  });

  testWidgets('a way of making a voice this Host lacks is shown held, with why',
      (tester) async {
    await _open(tester, FakeSpeechVoices(catalog: voiceCatalog(clone: false)));
    await tester.tap(find.text('我的声音'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-create')));
    await tester.pumpAndSettle();

    final clone =
        tester.widget<ListTile>(find.byKey(const Key('voice-create-clone')));
    expect(clone.enabled, isFalse);
    expect(find.text('这台主机的语音服务不支持'), findsOneWidget);
    expect(
        tester
            .widget<ListTile>(find.byKey(const Key('voice-create-design')))
            .enabled,
        isTrue);
  });

  testWidgets('a newly made voice is offered to the Eidolon right away',
      (tester) async {
    final voices = FakeSpeechVoices();
    await _open(tester, voices);
    await tester.tap(find.text('我的声音'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-create')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-create-design')));
    await tester.pumpAndSettle();

    await _reach(tester, find.text('温柔'));
    await _reach(tester, find.byKey(const Key('voice-design-generate')));
    await _reach(tester, find.byKey(const Key('voice-design-keep')));
    await tester.tap(find.byKey(const Key('voice-name-save')));
    await tester.pumpAndSettle();

    expect(find.text('现在给小禾用这个声音吗？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-use-new')));
    await tester.pumpAndSettle();
    expect(voices.chosen, [('o.d1', 1)]);
  });

  testWidgets('the row on the Eidolon page carries the same sentence',
      (tester) async {
    final voices = FakeSpeechVoices(
        current: companionVoiceView(
            selected: 'o.v2',
            selectedName: '妈妈的声音',
            reason: 'owner_voice_pending'));
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpeechVoiceTile(
            companionId: 'companion-a',
            voices: voices,
            onOpen: () async => opened++),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('「妈妈的声音」正在准备，暂用主机默认'), findsOneWidget);
    await tester.tap(find.byKey(const Key('companion-voice')));
    await tester.pumpAndSettle();
    expect(opened, 1);
    // Read again on the way back, so a change made there shows here.
    expect(voices.calls.where((c) => c == 'companion').length, 2);
  });
}
