/// When something happened, said the way a person reads it.
///
/// Shared rather than per-surface: the star map has rendered activity times
/// this way since it was written, and a Companion's 「上次对话」 is the same
/// question about a different row. Two formatters would mean one screen saying
/// 昨天 21:05 and another saying 2026-09-18T21:05:00Z about one instant.
///
/// Pure text. No Flutter, no feature imports — `features/constellation` and the
/// management surface both read from here, and nothing here reads from them.
library;

/// When something happened, at the grain a history needs.
///
/// A bare clock tells a reader nothing about which day they are looking at, and
/// a full timestamp is not how anybody says "yesterday evening". This is the
/// middle: the day when the day matters, the clock when it does not.
///
/// Local time, because the reader is in it. Null renders as an em dash rather
/// than as now: something with no instant is something the Host did not say the
/// instant of, and defaulting it to the present would make the oldest row look
/// newest.
String formatWhen(DateTime? at, {DateTime? now}) {
  if (at == null) return '—';
  final local = at.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final clock = '${two(local.hour)}:${two(local.minute)}';
  final sameDay =
      local.year == today.year &&
      local.month == today.month &&
      local.day == today.day;
  if (sameDay) return '今天 $clock';
  final yesterday = today.subtract(const Duration(days: 1));
  final wasYesterday =
      local.year == yesterday.year &&
      local.month == yesterday.month &&
      local.day == yesterday.day;
  if (wasYesterday) return '昨天 $clock';
  return '${local.month}月${local.day}日 $clock';
}

/// An ISO instant from a Host, or null when there is not one.
///
/// Empty is the Host's way of saying "no instant" and is not an error, so it is
/// not reported as one. A value that does not parse is treated the same way: a
/// row is worth showing without a time, and a screen is not the place to find
/// out that a Host sent something malformed.
DateTime? parseInstant(String? value) {
  final text = (value ?? '').trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text);
}

/// What to say under an Eidolon's name about when it was last used.
///
/// Never spoken to is a real state and says so. It is the state every new
/// Eidolon is in, and unlike the 「未运行」 this replaced it leads somewhere:
/// the thing to do about it is say something.
///
/// The caller passes null only when it knows the Host answered. When the Host
/// could not be asked, there is nothing truthful to put on the row — 「还没有
/// 聊过」 about an Eidolon somebody talks to daily is the same lie in a friendlier
/// voice — so the reason is said once for the screen and the row stays quiet.
String lastSpokenLine(DateTime? lastSpoken, {DateTime? now}) =>
    lastSpoken == null
    ? '还没有聊过'
    : '上次对话：${formatWhen(lastSpoken, now: now)}';
