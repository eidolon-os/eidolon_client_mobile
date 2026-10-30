import 'dart:typed_data';

import 'package:eidolon_client_mobile/src/features/speech_voice/owner_voice_page.dart';
import 'package:eidolon_client_mobile/src/features/speech_voice/voice_clone_page.dart';
import 'package:eidolon_client_mobile/src/features/speech_voice/voice_design_page.dart';
import 'package:eidolon_client_mobile/src/features/speech_voice/voice_reference_sources.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/speech_voice_fixtures.dart';

/// Making a voice and looking after one: what reaches the Host, and what the
/// person is told at each step.

/// Opens [page] on top of a home route, so popping it has somewhere to go and
/// what it pops with can be read.
Future<List<Object?>> _push(WidgetTester tester, Widget page) async {
  // A tall phone: these are long forms, and the tests are about what they
  // send, not about scrolling.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final popped = <Object?>[];
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async => popped.add(await Navigator.of(context)
              .push<Object?>(MaterialPageRoute(builder: (_) => page))),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return popped;
}

/// The page's own list, not the scrollable inside a text field.
Finder get _page => find
    .descendant(
        of: find.byType(ListView).last, matching: find.byType(Scrollable))
    .first;

/// Scrolls to [finder] and taps it. [settle] false for what follows a tap that
/// keeps something moving on purpose: a recording's clock, a review's spinner.
Future<void> _reach(WidgetTester tester, Finder finder,
    {bool settle = true}) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: _page);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Widget _design(FakeSpeechVoices voices) => VoiceDesignPage(
    companionName: '小禾',
    voices: voices,
    limits: voiceCatalog().limits,
    playerFactory: SilentPlayer.new);

Widget _clone(FakeSpeechVoices voices,
        {ReferenceRecorder? recorder, AudioFilePicker? file}) =>
    VoiceClonePage(
        voices: voices,
        limits: voiceCatalog().limits,
        processor: '阿里云百炼',
        playerFactory: SilentPlayer.new,
        recorderFactory: recorder == null ? null : () => recorder,
        filePicker: file);

Future<void> _consent(WidgetTester tester, {String who = '小禾'}) async {
  await tester.enterText(find.byKey(const Key('voice-clone-who')), who);
  await tester.tap(find.byKey(const Key('voice-clone-agree')));
  await tester.pump();
  await _reach(tester, find.byKey(const Key('voice-clone-continue')));
}

void main() {
  group('design', () {
    testWidgets(
        'asks for a description, then sends what was picked and written',
        (tester) async {
      final voices = FakeSpeechVoices();
      await _push(tester, _design(voices));

      final generate = find.byKey(const Key('voice-design-generate'));
      await tester.scrollUntilVisible(find.text('先选几个特点，或者写一句描述'), 200,
          scrollable: _page);
      expect(tester.widget<FilledButton>(generate).onPressed, isNull);

      await _reach(tester, find.text('女声'));
      await _reach(tester, find.text('温柔'));
      await tester.enterText(
          find.byKey(const Key('voice-design-prompt')), '像在讲睡前故事');
      await _reach(tester, generate);

      final body = voices.designs.single;
      expect(body.prompt, '女声，温柔。像在讲睡前故事');
      expect(body.previewText, startsWith('你好，我是小禾'));
      expect(body.name, '小禾的声音');
      // Generated, not played: hearing it is the person's tap.
      expect(find.byKey(const Key('voice-design-draft')), findsOneWidget);
    });

    testWidgets('换一个 throws the last draft away and asks afresh',
        (tester) async {
      final voices = FakeSpeechVoices();
      await _push(tester, _design(voices));
      await _reach(tester, find.text('沉稳'));
      await _reach(tester, find.byKey(const Key('voice-design-generate')));

      await _reach(tester, find.byKey(const Key('voice-design-again')));

      expect(voices.deleted, ['d1']);
      expect(voices.designs, hasLength(2));
      expect(
          voices.designs[0].operationId, isNot(voices.designs[1].operationId));
    });

    testWidgets('a lost answer is asked again as the same voice',
        (tester) async {
      var attempts = 0;
      final voices = FakeSpeechVoices()
        ..designAnswer = (body) {
          if (++attempts == 1) {
            throw const ManagementRequestException('生成声音超时');
          }
          return ownerVoiceView('d1', state: 'draft');
        };
      await _push(tester, _design(voices));
      await _reach(tester, find.text('沉稳'));
      await _reach(tester, find.byKey(const Key('voice-design-generate')));
      expect(find.text('生成声音超时'), findsOneWidget);

      await _reach(tester, find.byKey(const Key('voice-design-generate')));

      expect(voices.designs[0].operationId, voices.designs[1].operationId);
    });

    testWidgets('keeping it names it and hands it back', (tester) async {
      final voices = FakeSpeechVoices();
      final popped = await _push(tester, _design(voices));
      await _reach(tester, find.text('沉稳'));
      await _reach(tester, find.byKey(const Key('voice-design-generate')));
      await _reach(tester, find.byKey(const Key('voice-design-keep')));
      await tester.enterText(find.byKey(const Key('voice-name-field')), '午后');
      await tester.tap(find.byKey(const Key('voice-name-save')));
      await tester.pumpAndSettle();

      final (id, change) = voices.changes.single;
      expect(id, 'd1');
      expect(change.keep, isTrue);
      expect(change.name, '午后');
      expect((popped.single! as OwnerVoiceView).name, '午后');
    });

    testWidgets('leaving with a draft says it will be deleted, then deletes it',
        (tester) async {
      final voices = FakeSpeechVoices();
      final popped = await _push(tester, _design(voices));
      await _reach(tester, find.text('沉稳'));
      await _reach(tester, find.byKey(const Key('voice-design-generate')));

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('未保存的声音会被删除。'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-design-discard')));
      await tester.pumpAndSettle();

      expect(voices.deleted, ['d1']);
      expect(popped, [null]);
    });
  });

  group('clone', () {
    testWidgets('nothing starts before the speaker is named and has agreed',
        (tester) async {
      await _push(tester, _clone(FakeSpeechVoices()));

      expect(find.textContaining('云端语音服务（阿里云百炼）'), findsOneWidget);
      final next = find.byKey(const Key('voice-clone-continue'));
      await tester.scrollUntilVisible(next, 200, scrollable: _page);
      expect(tester.widget<FilledButton>(next).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('voice-clone-who')), '小禾');
      await tester.pump();
      expect(tester.widget<FilledButton>(next).onPressed, isNull);
      await tester.tap(find.byKey(const Key('voice-clone-agree')));
      await tester.pump();
      expect(tester.widget<FilledButton>(next).onPressed, isNotNull);
    });

    testWidgets(
        'a recording cannot end before ten seconds, and carries consent',
        (tester) async {
      final voices = FakeSpeechVoices();
      final recorder = ScriptedRecorder();
      await _push(tester, _clone(voices, recorder: recorder));
      await _consent(tester, who: '小禾');
      await _reach(tester, find.byKey(const Key('voice-clone-record')),
          settle: false);

      expect(find.textContaining('我是小禾，我同意用我的声音为 Eidolon 生成一个声音。'),
          findsOneWidget);
      final stop = find.byKey(const Key('voice-clone-stop'));
      recorder.speak(5000);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<FilledButton>(stop).onPressed, isNull);
      expect(find.text('至少录 10 秒'), findsOneWidget);

      recorder.speak(6000);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(stop);
      await tester.pumpAndSettle();

      // Eleven seconds of 24 kHz PCM16, as a WAV.
      expect(voices.checks.single, (44 + 11 * 48000, null));
      expect(recorder.stopped, isTrue);
      await _reach(tester, find.byKey(const Key('voice-clone-submit')),
          settle: false);

      final body = voices.clones.single;
      expect(body.name, '我的声音');
      expect(body.audioBase64, 'UklGRg==');
      expect(body.consent.method, 'spoken');
      expect(body.consent.subject, 'self');
      expect(body.consent.statement, contains('我是小禾'));
      expect(body.consent.consentVersion, consentVersion);
      expect(find.byKey(const Key('voice-clone-preparing')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a recording stops by itself at the longest allowed',
        (tester) async {
      final voices = FakeSpeechVoices();
      final recorder = ScriptedRecorder();
      await _push(tester, _clone(voices, recorder: recorder));
      await _consent(tester);
      await _reach(tester, find.byKey(const Key('voice-clone-record')),
          settle: false);

      recorder.speak(25000);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(voices.checks, hasLength(1));
      expect(find.byKey(const Key('voice-clone-check')), findsOneWidget);
    });

    testWidgets('a file is attested, measured, and its window can move',
        (tester) async {
      final voices = FakeSpeechVoices()
        ..checkAnswer = (audio, startMs) => ReferenceCheckView(
            accepted: true,
            problems: const [],
            durationMs: 40000,
            windowStartMs: startMs ?? 3000,
            windowMs: 20000,
            audioBase64: 'UklGRg==');
      await _push(
          tester, _clone(voices, file: GivenFile('妈妈.m4a', Uint8List(1000))));
      await tester.tap(find.text('家人或朋友'));
      await _consent(tester, who: '妈妈');
      await _reach(tester, find.byKey(const Key('voice-clone-file')));

      expect(voices.checks.single, (1000, null));
      expect(find.text('会用第 3～23 秒'), findsOneWidget);
      await tester.drag(
          find.byKey(const Key('voice-clone-window')), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(voices.checks, hasLength(2));
      expect(voices.checks.last.$2, isNotNull);

      await _reach(tester, find.byKey(const Key('voice-clone-submit')),
          settle: false);
      final body = voices.clones.single;
      expect(body.name, '妈妈的声音');
      expect(body.consent.method, 'attested');
      expect(body.consent.subject, 'other');
      expect(body.consent.subjectLabel, '妈妈');
      expect(body.consent.statement, isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a file too large is refused here, before it is even read',
        (tester) async {
      final voices = FakeSpeechVoices();
      final picker = GivenFile('big.wav', Uint8List(10 * 1024 * 1024 + 1));
      await _push(tester, _clone(voices, file: picker));
      await _consent(tester);
      await _reach(tester, find.byKey(const Key('voice-clone-file')));

      expect(picker.read, isFalse);
      expect(voices.checks, isEmpty);
      expect(find.text('文件太大，请选择 10 MB 以内的文件'), findsOneWidget);
    });

    testWidgets('what is wrong with a recording is said, and no submit offered',
        (tester) async {
      final voices = FakeSpeechVoices()
        ..checkAnswer = (_, __) => const ReferenceCheckView(
            accepted: false,
            problems: ['too_little_speech', 'clipping'],
            durationMs: 12000,
            windowStartMs: 0,
            windowMs: 12000);
      await _push(
          tester, _clone(voices, file: GivenFile('a.wav', Uint8List(1000))));
      await _consent(tester);
      await _reach(tester, find.byKey(const Key('voice-clone-file')));

      expect(find.text('说话时间不足 5 秒\n有爆音，请离远一点或小声一些'), findsOneWidget);
      expect(find.byKey(const Key('voice-clone-submit')), findsNothing);
      expect(find.text('换一个文件'), findsOneWidget);
    });

    testWidgets('the review is followed until it is decided', (tester) async {
      final voices = FakeSpeechVoices();
      voices.reviews.addAll([
        ownerVoiceView('k1', method: 'clone', status: 'preparing'),
        ownerVoiceView('k1', method: 'clone', status: 'ready', name: '我的声音'),
      ]);
      final popped = await _push(
          tester, _clone(voices, file: GivenFile('a.wav', Uint8List(1000))));
      await _consent(tester);
      await _reach(tester, find.byKey(const Key('voice-clone-file')));
      await _reach(tester, find.byKey(const Key('voice-clone-submit')),
          settle: false);
      expect(find.byKey(const Key('voice-clone-preparing')), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.byKey(const Key('voice-clone-ready')), findsOneWidget);

      await _reach(tester, find.text('完成'));
      expect((popped.single! as OwnerVoiceView).status, 'ready');
    });

    testWidgets('a rejected voice is cleared away when recording again',
        (tester) async {
      final voices = FakeSpeechVoices();
      voices.reviews.add(ownerVoiceView('k1',
          method: 'clone', status: 'rejected', statusDetail: '录音里有多个人在说话'));
      await _push(
          tester, _clone(voices, file: GivenFile('a.wav', Uint8List(1000))));
      await _consent(tester);
      await _reach(tester, find.byKey(const Key('voice-clone-file')));
      await _reach(tester, find.byKey(const Key('voice-clone-submit')),
          settle: false);

      expect(find.text('录音里有多个人在说话'), findsOneWidget);
      await _reach(tester, find.text('重新录'));

      expect(voices.deleted, ['k1']);
      expect(find.byKey(const Key('voice-clone-record')), findsOneWidget);
    });
  });

  group('one of my voices', () {
    Widget page(FakeSpeechVoices voices, OwnerVoiceView voice) =>
        OwnerVoicePage(
            voice: voice,
            voices: voices,
            companionNames: const {'companion-a': '小禾', 'companion-b': '阿福'},
            playerFactory: SilentPlayer.new);

    testWidgets('renaming sends the new name against its revision',
        (tester) async {
      final voices = FakeSpeechVoices();
      await _push(tester, page(voices, ownerVoiceView('v1', revision: 3)));

      await tester.tap(find.byKey(const Key('owner-voice-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('voice-name-field')), '晚安');
      await tester.tap(find.byKey(const Key('voice-name-save')));
      await tester.pumpAndSettle();

      final (_, change) = voices.changes.single;
      expect(change.name, '晚安');
      expect(change.expectedRevision, 3);
      expect(find.text('晚安'), findsWidgets);
    });

    testWidgets('dropping the recording says what is lost, then drops it',
        (tester) async {
      final voices = FakeSpeechVoices();
      await _push(
          tester,
          page(voices,
              ownerVoiceView('v1', method: 'clone', hasReference: true)));

      await tester.tap(find.byKey(const Key('owner-voice-drop-reference')));
      await tester.pumpAndSettle();
      expect(find.textContaining('没法再用这段录音自动重新生成它'), findsOneWidget);
      await tester.tap(find.byKey(const Key('owner-voice-confirm')));
      await tester.pumpAndSettle();

      expect(voices.changes.single.$2.dropReference, isTrue);
      expect(find.byKey(const Key('owner-voice-drop-reference')), findsNothing);
    });

    testWidgets('deleting names who will go back to the Host voice',
        (tester) async {
      final voices = FakeSpeechVoices(mine: [
        ownerVoiceView('v1', usedBy: ['companion-b'])
      ]);
      final popped = await _push(
          tester, page(voices, ownerVoiceView('v1', usedBy: ['companion-b'])));

      await tester.tap(find.byKey(const Key('owner-voice-delete')));
      await tester.pumpAndSettle();
      expect(find.text('阿福正在用它，删除后会改用主机默认的声音。删除后不能恢复。'), findsOneWidget);
      await tester.tap(find.byKey(const Key('owner-voice-confirm')));
      await tester.pumpAndSettle();

      expect(voices.deleted, ['v1']);
      expect(popped, [null]);
    });
  });
}
