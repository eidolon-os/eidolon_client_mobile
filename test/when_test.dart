/// How this app writes an instant, in one place.
///
/// The formatter had one caller — the star map's activity history — until a
/// Companion roster needed the same sentence. It moved rather than being copied
/// for the reason the Companion vocabulary moved before it: two ways to write a
/// time is two screens disagreeing about one instant.
library;

import 'package:eidolon_client_mobile/src/models/when.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A fixed reader's "now", so these assertions do not depend on the day or the
  // timezone of whatever machine runs them.
  final now = DateTime(2026, 9, 19, 11, 0);

  group('formatWhen', () {
    test('within today, the clock is enough', () {
      expect(formatWhen(DateTime(2026, 9, 19, 9, 5), now: now), '今天 09:05');
    });

    test('yesterday is said as yesterday', () {
      expect(formatWhen(DateTime(2026, 9, 18, 21, 30), now: now), '昨天 21:30');
    });

    test('further back carries the day, because a clock alone would not', () {
      expect(formatWhen(DateTime(2026, 9, 15, 20, 0), now: now), '9月15日 20:00');
    });

    test('it is yesterday by the calendar, not by twenty-four hours', () {
      // 23:50 the previous evening is twelve hours ago and is still 昨天; 00:10
      // this morning is eleven hours ago and is 今天. Anything measuring elapsed
      // time instead would call the first 今天 and read as wrong to a person
      // who remembers going to bed in between.
      expect(formatWhen(DateTime(2026, 9, 18, 23, 50), now: now), '昨天 23:50');
      expect(formatWhen(DateTime(2026, 9, 19, 0, 10), now: now), '今天 00:10');
    });

    test('no instant renders as one, and never as now', () {
      // Defaulting a missing instant to the present would sort the oldest row
      // to the top of a history and call it the newest thing that happened.
      expect(formatWhen(null, now: now), '—');
    });
  });

  group('parseInstant', () {
    test('a Host that says nothing is saying "no instant", not failing', () {
      expect(parseInstant(''), isNull);
      expect(parseInstant(null), isNull);
      expect(parseInstant('   '), isNull);
    });

    test('the offset the Host sent is kept, not reinterpreted', () {
      expect(
        parseInstant('2026-09-18T09:30:00+00:00'),
        DateTime.utc(2026, 9, 18, 9, 30),
      );
    });

    test('something unparseable costs a time, not a row', () {
      // A screen is the wrong place to find out a Host sent something malformed.
      expect(parseInstant('whenever'), isNull);
    });
  });

  group('lastSpokenLine', () {
    test('never spoken to is a state, and it says so', () {
      // What a new Eidolon is in, and what 「未运行」 used to be printed over.
      expect(lastSpokenLine(null, now: now), '还没有聊过');
    });

    test('otherwise it is when', () {
      expect(
        lastSpokenLine(DateTime(2026, 9, 18, 21, 30), now: now),
        '上次对话：昨天 21:30',
      );
    });
  });
}
