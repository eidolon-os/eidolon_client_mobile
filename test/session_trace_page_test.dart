/// The engineering drill-down: when it is offered, and what it says.
///
/// Two things are held here. The entry is **absent** unless the Host gave a
/// session to open — this codebase keeps finding buttons in front of impossible
/// events, and a disabled one is the same dead end with extra steps. And the
/// screen never turns a missing measurement into a number: a stage the turn
/// never reached reads as 未测到, not as 0ms.
library;

import 'package:eidolon_client_mobile/src/features/constellation/cockpit_details.dart';
import 'package:eidolon_client_mobile/src/features/constellation/cockpit_models.dart';
import 'package:eidolon_client_mobile/src/features/constellation/session_trace_page.dart';
import 'package:eidolon_client_mobile/src/features/constellation/session_trace_wire.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CockpitActivity _activity() => CockpitActivity(
  activityId: 'a-1',
  kind: 'voice_turn',
  companionId: 'c-1',
  status: 'completed',
  outcome: 'success',
  summary: '一次对话',
  turnId: 't-1',
);

CockpitTurn _turn({String runtimeSessionId = 'esp32-1'}) => CockpitTurn(
  turnId: 't-1',
  companionId: 'c-1',
  status: 'completed',
  latencyMs: 1200,
  breakdown: const [CockpitTurnPhase(key: 'first_delta', label: '等到第一个字', latencyMs: 800)],
  runtimeSessionId: runtimeSessionId,
);

SessionTrace _trace({
  String status = 'closed',
  List<String>? missing = const ['avatar_ready'],
  int dropped = 0,
}) => SessionTrace(
  session: SessionTraceSummary(
    sessionId: 'esp32-1',
    ownerId: 'owner-1',
    companionId: 'c-1',
    roomName: 'room-1',
    interactionMode: 'full_duplex',
    startedAt: '2026-09-16T01:30:33+08:00',
    status: status,
    reason: status == 'closed' ? 'session_ended' : '',
    durationMs: status == 'closed' ? 70515.1 : null,
    marks: const {'room_joined': -110.4, 'first_turn': 4667.5},
    missingMarks: missing,
    traceBytes: 48698,
    droppedRecordCount: dropped,
    truncated: false,
  ),
  turns: const [
    SessionTraceTurn(
      turnId: 't-1',
      reason: 'agent_audio_playback_done',
      durations: [
        TraceDuration(key: 'speech_stop_to_commit', ms: 185.9),
        TraceDuration(key: 'vad_start_to_interrupt_resolved', ms: null),
      ],
    ),
  ],
  eventCount: 14,
  recordCount: 22,
);

Future<void> _pumpSheet(
  WidgetTester tester, {
  required CockpitTurn turn,
  void Function(String)? onOpen,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: activitySheetBody(
          _activity(),
          '砚舟',
          turn: turn,
          onOpenSessionTrace: onOpen,
        ),
      ),
    ),
  ),
);

Future<void> _pumpPage(
  WidgetTester tester,
  SessionTraceReader read,
) async {
  await tester.pumpWidget(
    MaterialApp(home: SessionTracePage(sessionId: 'esp32-1', read: read)),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('下钻入口', () {
    testWidgets('主机给了会话名，才有这个入口', (tester) async {
      var opened = '';
      await _pumpSheet(tester, turn: _turn(), onOpen: (id) => opened = id);

      await tester.tap(find.byKey(const Key('open-session-trace')));
      expect(opened, 'esp32-1');
    });

    testWidgets('没有会话名就不画按钮 —— 不是画一个按不动的', (tester) async {
      await _pumpSheet(
        tester,
        turn: _turn(runtimeSessionId: ''),
        onOpen: (_) {},
      );

      // 一个点下去没有东西可看的按钮，就是这个仓一直在拔掉的那种死屏入口。
      expect(find.byKey(const Key('open-session-trace')), findsNothing);
    });
  });

  group('一次会话的链路屏', () {
    testWidgets('判词说出时长和结束原因', (tester) async {
      await _pumpPage(tester, (_) async => _trace());

      expect(find.byKey(const Key('session-trace-verdict')), findsOneWidget);
      expect(find.textContaining('session_ended'), findsOneWidget);
    });

    testWidgets('没测到的阶段说未测到，不说 0ms', (tester) async {
      await _pumpPage(tester, (_) async => _trace());

      // 「没走到这一步」和「这一步没花时间」必须不一样。
      expect(find.text('未测到'), findsOneWidget);
      expect(find.textContaining('0.0ms'), findsNothing);
    });

    testWidgets('未测到贴在自己的键下面，不是飘在右边', (tester) async {
      await _pumpPage(tester, (_) async => _trace());

      final unmeasured = tester.widget<Text>(find.text('未测到'));
      final measured = tester.widget<Text>(find.text('185.9ms'));

      // 有条的行，数字右对齐成一列，方便扫。没条的行右对齐就会横跨一片空白，
      // 离下一个键比离自己的键还近 —— 而干净的会话里大多数阶段都是没测到的，
      // 所以那是常态不是例外。
      expect(measured.textAlign, TextAlign.right);
      expect(unmeasured.textAlign, isNot(TextAlign.right));
    });

    testWidgets('还开着的会话不说它缺了什么', (tester) async {
      await _pumpPage(
        tester,
        (_) async => _trace(status: 'open', missing: null),
      );

      // 还没结束就可能还会走到，所以不能列成缺席。
      expect(
        find.byKey(const Key('session-trace-marks-unknown')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('session-trace-marks-missing')), findsNothing);
    });

    testWidgets('结束了才列出没走到的环节', (tester) async {
      await _pumpPage(tester, (_) async => _trace());

      expect(
        find.byKey(const Key('session-trace-marks-missing')),
        findsOneWidget,
      );
      expect(find.textContaining('avatar_ready'), findsOneWidget);
    });

    testWidgets('丢过记录要说出来，不能让屏幕看起来是完整的', (tester) async {
      await _pumpPage(tester, (_) async => _trace(dropped: 3));

      expect(
        find.byKey(const Key('session-trace-incomplete')),
        findsOneWidget,
      );
    });

    testWidgets('读不到就说主机的原话，并给重试', (tester) async {
      var attempts = 0;
      await _pumpPage(tester, (_) async {
        attempts += 1;
        throw Exception('主机拒绝了：channel provider 不可用');
      });

      expect(find.textContaining('channel provider 不可用'), findsOneWidget);
      await tester.tap(find.byKey(const Key('session-trace-retry')));
      await tester.pumpAndSettle();
      expect(attempts, 2);
    });
  });
}
