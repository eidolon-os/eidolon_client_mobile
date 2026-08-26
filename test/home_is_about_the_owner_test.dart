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
  HostHome home({
    List<Map<String, dynamic>>? companions,
    String? defaultId = 'c-a',
    String runtimeUnavailable = '',
  }) =>
      HostHome.fromView(
        HomeView.fromJson({
          'contract_version': '1',
          'owner_display_name': 'Manson',
          'owner_revision': 3,
          'companions': companions ??
              [
                {
                  'companion_id': 'c-a',
                  'display_name': '小忆',
                  'kind': 'conversational',
                  'lifecycle_state': 'active',
                  'revision': 4,
                  'created_at': '2026-08-01T00:00:00+00:00',
                  'updated_at': '2026-08-01T00:00:00+00:00',
                  'running': true,
                  'last_active_at': '2026-08-26T09:30:00+00:00',
                },
                {
                  'companion_id': 'c-b',
                  'display_name': '阿力',
                  'kind': 'conversational',
                  'lifecycle_state': 'active',
                  'revision': 2,
                  'created_at': '2026-08-02T00:00:00+00:00',
                  'updated_at': '2026-08-02T00:00:00+00:00',
                  'running': true,
                  'last_active_at': '2026-08-26T09:20:00+00:00',
                },
              ],
          'default_companion_id': defaultId,
          'runtime_unavailable': runtimeUnavailable,
          'memory': '记着 42 条',
          'companion_counts': {
            'total': 2,
            'ready': 2,
            'waiting': 0,
            'put_away': 0,
          },
          'devices': {'total': 0, 'ready': 0, 'waiting': 0, 'put_away': 0},
          'machine_attention': <String>[],
          'unavailable': <String, String>{},
        }),
      );

  test('several Eidolons can be running at the same time', () {
    // The case a single promoted Companion could not express at all.
    expect(home().companions.where((row) => row.running == true).length, 2);
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

  test('an unreadable runtime leaves running unknown, not false', () {
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
          'running': null,
          'last_active_at': '',
        },
      ],
      runtimeUnavailable: 'runtime_starting',
    );

    expect(answer.companions.single.running, isNull);
    expect(answer.runtimeUnavailable, 'runtime_starting');
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
}
