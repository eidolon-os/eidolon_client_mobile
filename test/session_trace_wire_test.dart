/// The session-trace document, read the way the Host sends it.
///
/// The shapes here were taken from a real recording on a real board rather than
/// imagined — a previous bug in this line came from a test double that agreed
/// with a misunderstanding, so the structure below (record kinds, the nullable
/// durations, `missing_session_marks` being absent while a session is open)
/// mirrors what the Provider actually returned. Values are synthetic because
/// the real records carry conversation text in `attrs`, which has no business
/// in this repository.
library;

import 'package:eidolon_client_mobile/src/features/constellation/session_trace_wire.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _session({
  String status = 'closed',
  Object? missing = const ['avatar_ready'],
  Object? duration = 70515.1,
}) => <String, Object?>{
  'session_id': 'esp32-a3c0b315-00000004',
  'owner_id': 'owner-1',
  'companion_id': 'companion-1',
  'room_name': 'eidolon-device-e42',
  'interaction_mode': 'full_duplex',
  'started_at': '2026-09-16T01:30:33.789781+08:00',
  'trace_bytes': 48698,
  'status': status,
  'reason': status == 'closed' ? 'session_ended' : '',
  'duration_ms': duration,
  'session_marks_ms': <String, Object?>{
    'room_joined': -110.4,
    'runtime_participant_resolved': 1.2,
    'warmup_done': 184.3,
    'session_started': 353.3,
    'first_turn': 4667.5,
  },
  'missing_session_marks': missing,
  'written_record_count': 22,
  'dropped_record_count': 0,
  'truncated': false,
};

Map<String, Object?> _document({
  Object? missing = const ['avatar_ready'],
  String status = 'closed',
}) => <String, Object?>{
  'operation': 'channel.session-trace',
  'session': _session(status: status, missing: missing),
  'records': <Object?>[
    {'record_kind': 'session_open', 'session_id': 'esp32-a3c0b315-00000004'},
    {'record_kind': 'session_mark', 'mark': 'room_joined'},
    {'record_kind': 'event', 'event_type': 'channel.turn.phase_changed'},
    {'record_kind': 'event', 'event_type': 'channel.turn.milestone'},
    // A progress row for the same turn as the final one below.
    {'record_kind': 'turn_progress', 'turn_id': 't-1', 'durations_ms': {}},
    {
      'record_kind': 'turn_final',
      'turn_id': 't-1',
      'record_reason': 'agent_audio_playback_done',
      'durations_ms': <String, Object?>{
        'vad_start_to_interrupt_resolved': null,
        'speech_stop_to_commit': 185.958,
        'commit_to_llm_first_delta': 824.266,
      },
    },
    {'record_kind': 'session_close'},
  ],
  'record_count': 7,
};

void main() {
  group('一次会话的记录', () {
    test('只数已经settle的轮次，不把同一轮数两遍', () {
      final trace = sessionTraceFromJson(_document());

      // turn_progress 和 turn_final 是同一轮。写入方分这两种 record_kind
      // 就是为了让读取方能取后者；两个都算会让一轮显示成两轮。
      expect(trace.turns, hasLength(1));
      expect(trace.turns.single.turnId, 't-1');
      expect(trace.turns.single.reason, 'agent_audio_playback_done');
    });

    test('没测到的阶段保持为空，不变成 0', () {
      final durations = sessionTraceFromJson(_document()).turns.single.durations;

      final unmeasured = durations.firstWhere(
        (d) => d.key == 'vad_start_to_interrupt_resolved',
      );
      expect(unmeasured.ms, isNull);
      expect(unmeasured.measured, isFalse);
      // 「没走到这一步」和「这一步没花时间」是两件事，屏幕上不能长一样。
      expect(durations.where((d) => d.measured), hasLength(2));
    });

    test('阶段顺序按写入方给的来，不按耗时排', () {
      final keys = sessionTraceFromJson(
        _document(),
      ).turns.single.durations.map((d) => d.key).toList();

      // 按大小排会把一条流水线打散成一张排行榜。
      expect(keys, [
        'vad_start_to_interrupt_resolved',
        'speech_stop_to_commit',
        'commit_to_llm_first_delta',
      ]);
    });

    test('事件只计数，不在这里再讲一遍', () {
      // 事件是驾驶舱画的那一层；这块屏重复它就是同一件事说两遍。
      expect(sessionTraceFromJson(_document()).eventCount, 2);
    });

    test('会话还开着的时候，"缺哪些 mark" 是未知而不是空', () {
      final open = sessionTraceFromJson(
        _document(status: 'open', missing: null),
      ).session;
      final closed = sessionTraceFromJson(_document()).session;

      // 还没结束的会话可能仍会走到那些 mark，所以是 null；已结束才是一份名单。
      expect(open.missingMarks, isNull);
      expect(open.closed, isFalse);
      expect(closed.missingMarks, ['avatar_ready']);
      expect(closed.closed, isTrue);
    });

    test('会话尺度的 mark 保持写入顺序', () {
      final marks = sessionTraceFromJson(_document()).session.marks;

      expect(marks.keys.toList(), [
        'room_joined',
        'runtime_participant_resolved',
        'warmup_done',
        'session_started',
        'first_turn',
      ]);
      // 负数是真的：room_joined 早于 writer 打开文件的那一刻。
      expect(marks['room_joined'], lessThan(0));
    });

    test('丢过记录就要说出来', () {
      final intact = sessionTraceFromJson(_document()).session;
      expect(intact.lostRecords, isFalse);

      final lossy = Map<String, Object?>.from(_document());
      lossy['session'] = <String, Object?>{
        ..._session(),
        'dropped_record_count': 3,
      };
      // 队列满时写入方丢记录并计数。瞒着读者等于用沉默撒谎。
      expect(sessionTraceFromJson(lossy).session.lostRecords, isTrue);
    });

    test('载荷不成形就拒绝，不半懂着渲染', () {
      expect(
        () => sessionTraceFromJson(<String, Object?>{'session': 'nope'}),
        throwsA(isA<SessionTraceException>()),
      );
    });
  });

  group('会话列表', () {
    test('主机不记录 与 这位主人没有会话，是两回事', () {
      final off = sessionTraceListingFromJson(<String, Object?>{
        'recording': false,
        'sessions': <Object?>[],
      });
      final onButEmpty = sessionTraceListingFromJson(<String, Object?>{
        'recording': true,
        'sessions': <Object?>[],
      });

      // 这两种情况在屏幕上必须说不同的话 —— 这正是整条工作线要消灭的同形失败。
      expect(off.recording, isFalse);
      expect(onButEmpty.recording, isTrue);
      expect(off.sessions, isEmpty);
      expect(onButEmpty.sessions, isEmpty);
    });

    test('列表里的每一行就是详情里的那份摘要', () {
      final listing = sessionTraceListingFromJson(<String, Object?>{
        'recording': true,
        'sessions': <Object?>[_session()],
      });

      expect(listing.sessions.single.sessionId, 'esp32-a3c0b315-00000004');
      expect(listing.sessions.single.durationMs, 70515.1);
    });
  });
}
