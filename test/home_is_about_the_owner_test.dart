import 'package:flutter_test/flutter_test.dart';

import 'package:eidolon_client_mobile/src/features/host_setup/home_models.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';

/// The Owner's view is about the Owner and their Eidolons — plural.
///
/// It was not. The Host led with `answering`: one Companion, promoted, carrying
/// every rich fact while the others were a number. That made
/// `default_companion_id` — a routing fallback, explicitly not a rank — the
/// subject of a person's own home screen, and it could not represent two
/// Eidolons being live at once, which is ordinary.
///
/// These tests hold the three properties that correction rests on: the model
/// carries a list, several rows can be running, and "who replies unaddressed"
/// is a marker on the set rather than the shape of it.
void main() {
  /// Two rows unless a test says otherwise, and the counts read off the rows.
  ///
  /// Derived rather than written twice: a fixture whose count disagrees with
  /// its list can make the screen look right while the rule under test is
  /// wrong, which is the one thing these tests are for.
  HostHome home({
    List<Map<String, dynamic>>? companions,
    String? defaultId = 'c-a',
    String activityUnavailable = '',
    String memory = '记着 42 条',
    Map<String, String> unavailable = const {},
    bool moreCompanions = false,
  }) {
    final rows = companions ??
        [
          {
            'companion_id': 'c-a',
            'display_name': '小忆',
            'kind': 'conversational',
            'lifecycle_state': 'active',
            'revision': 4,
            'created_at': '2026-08-01T00:00:00+00:00',
            'updated_at': '2026-08-01T00:00:00+00:00',
            'last_active_at': '2026-09-18T09:30:00+00:00',
          },
          {
            'companion_id': 'c-b',
            'display_name': '阿力',
            'kind': 'conversational',
            'lifecycle_state': 'active',
            'revision': 2,
            'created_at': '2026-08-02T00:00:00+00:00',
            'updated_at': '2026-08-02T00:00:00+00:00',
            'last_active_at': '2026-09-15T20:00:00+00:00',
          },
        ];
    final active =
        rows.where((row) => row['lifecycle_state'] == 'active').length;
    return HostHome.fromView(
      HomeView.fromJson({
        'contract_version': '1',
        'owner_display_name': 'Manson',
        'owner_revision': 3,
        'companions': rows,
        'default_companion_id': defaultId,
        'activity_unavailable': activityUnavailable,
        'memory': memory,
        'companion_counts': {
          'total': rows.length,
          'ready': active,
          'waiting': 0,
          'put_away': rows.length - active,
        },
        'devices': {'total': 0, 'ready': 0, 'waiting': 0, 'put_away': 0},
        'machine_attention': <String>[],
        'more_companions': moreCompanions,
        'unavailable': unavailable,
      }),
    );
  }

  test('every row carries when this person last spoke to it', () {
    // The fact that tells a used Eidolon from a forgotten one, and the one
    // people were reading 「运行中 / 未运行」 as an answer to.
    expect(
      home().companions.map((row) => row.lastSpokenAt),
      [
        DateTime.parse('2026-09-18T09:30:00+00:00'),
        DateTime.parse('2026-09-15T20:00:00+00:00'),
      ],
    );
  });

  test('who replies unaddressed is a marker, not the subject', () {
    final answer = home();

    expect(answer.defaultCompanionId, 'c-a');
    // And it is exactly one of the rows — not a separate, richer object beside
    // them, which is what let it accumulate facts the others never got.
    expect(answer.answering?.companionId, 'c-a');
    expect(answer.companions.map((row) => row.companionId), contains('c-a'));
  });

  test('nobody named is an ordinary state, not a missing subject', () {
    // Every Eidolon put away, or the Owner has not chosen. The list is
    // unaffected, because the screen was never about the default one.
    final answer = home(defaultId: null);

    expect(answer.defaultCompanionId, isNull);
    expect(answer.answering, isNull);
    expect(answer.companions, hasLength(2));
  });

  test('an unreadable runtime is named, so a blank time is not read as never', () {
    // Both cases arrive as no time. Only the named one is unknown, and a screen
    // that showed 「还没有聊过」 for it would be saying something false about an
    // Eidolon this person may talk to every day.
    final answer = home(
      companions: [
        {
          'companion_id': 'c-a',
          'display_name': '小忆',
          'kind': 'conversational',
          'lifecycle_state': 'active',
          'revision': 4,
          'created_at': '2026-08-01T00:00:00+00:00',
          'updated_at': '2026-08-01T00:00:00+00:00',
          'last_active_at': '',
        },
      ],
      activityUnavailable: 'runtime_starting',
    );

    expect(answer.companions.single.lastSpokenAt, isNull);
    expect(answer.activityUnavailable, 'runtime_starting');
  });

  test('the memory belongs to the person, not to one of their Eidolons', () {
    // One Realm per Owner, every Eidolon reading it through an audience. This
    // used to hang off whichever Companion answered.
    expect(home().memory, '记着 42 条');
  });

  test('a new Eidolon is recognised by membership, not by being the default',
      () {
    // The setup check used to ask whether the newly created Companion was the
    // promoted one. A new Eidolon is not necessarily the one that answers, and
    // treating that as a mismatch refused to show a person their own Host.
    final answer = home();

    expect(answer.answersFor('c-b'), isTrue);
    expect(answer.answersFor('c-a'), isTrue);
    expect(answer.answersFor('c-nope'), isFalse);
    expect(answer.answersFor(null), isTrue);
  });

  group('a part the Host could not read is not a part that is empty', () {
    test('a roster nobody could read does not invite creating the first one', () {
      // Both arrive as an empty list and a zero count. Only one of them means
      // 「你没有伙伴」, and the other one put that sentence — with 去新建第一位
      // after it — in front of people who have three.
      final unread = home(
        companions: const [],
        unavailable: const {'companions': 'companion authority is away'},
      );

      expect(unread.companionsUnread, isTrue);
      expect(companionsSummaryLine(unread), '这台主机这次没能读到你的伙伴');
    });

    test('an Owner who really has none still gets the invitation', () {
      // The other half of the same test: the honest empty state has to survive
      // the fix, or the screen has traded one wrong sentence for another.
      final empty = home(companions: const [], defaultId: null);

      expect(empty.companionsUnread, isFalse);
      expect(companionsSummaryLine(empty), '还没有伙伴，去新建第一位');
    });

    test('a memory nobody could read does not read as a memory with nothing in it',
        () {
      final unread = home(
        memory: '',
        unavailable: const {'memory': 'memory service is away'},
      );

      expect(unread.memoryUnread, isTrue);
      expect(
        memorySummaryLine(unread, failed: false),
        '这台主机这次没能读到记忆概览',
      );
    });

    test('an empty summary is treated as unread even undeclared', () {
      // The Host only leaves this empty when the read failed, so a blank that
      // arrived without a reason beside it is still a blank nobody can vouch
      // for — and it must not be dressed up as 「还没记下什么」.
      expect(
        memorySummaryLine(home(memory: ''), failed: false),
        '这台主机这次没能读到记忆概览',
      );
    });

    test('what the Host did say is relayed, not restated', () {
      // 「还没记下什么」 is the Host's own sentence for a memory nothing has
      // been written into. It reaches the screen from there rather than from a
      // second copy on this side.
      expect(
        memorySummaryLine(home(memory: '还没记下什么'), failed: false),
        '还没记下什么，留在这台主机上，没有离开过',
      );
      expect(
        memorySummaryLine(home(memory: '记着 42 条'), failed: false),
        '记着 42 条，留在这台主机上，没有离开过',
      );
    });

    test('nothing read yet is told apart from a read that came back refused', () {
      expect(memorySummaryLine(null, failed: false), '正在读取记忆概览');
      expect(memorySummaryLine(null, failed: true), '暂时无法读取记忆概览');
    });

    test('a page of the roster is not reported as the whole of it', () {
      // The home reads one page. Counting it and printing the number as a
      // total tells anybody past the page boundary that the page size is how
      // many Eidolons they have — and it never grows again to say otherwise.
      final page = home(moreCompanions: true);

      expect(page.moreCompanions, isTrue);
      expect(page.companionCounts.total, 2, reason: 'what this answer carries');
    });

    test('a roster that fits does not look truncated', () {
      expect(home().moreCompanions, isFalse);
    });

    test('a part that was read is not reported as missing', () {
      final whole = home();

      expect(whole.companionsUnread, isFalse);
      expect(whole.memoryUnread, isFalse);
      expect(whole.sawEverything, isTrue);
    });
  });
}
