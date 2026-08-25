import 'package:flutter/material.dart';

import 'management_client.dart';

/// What a screen shows when the Host would not answer.
///
/// One widget, because there were ten copies of it. Each was a `Text('$_error')`
/// beside an unconditional 再试一次, and the uniformity was the problem rather
/// than the point: every one of them printed the exception, so a Host missing a
/// credential, a service that had not started and a lost race all rendered the
/// same four characters, under a button that could only help with one of them.
///
/// Two things this fixes by construction:
///
/// - **The wording is not the screen's decision.** [refusalText] owns it, so a
///   new screen cannot word a refusal differently, and improving one sentence
///   improves it everywhere.
/// - **Retry is offered only when retrying could work.** The Host says whether
///   waiting changes the answer; a screen that showed the button anyway was
///   making a promise the product could not keep.
class RefusalNotice extends StatelessWidget {
  const RefusalNotice({
    super.key,
    required this.error,
    required this.subject,
    this.onRetry,
    this.retryKey,
  });

  /// Whatever was caught. Not narrowed to [ManagementRequestException]: a socket
  /// error is also something a person is owed a sentence about, and forcing each
  /// screen to sort them out first is how they came to print `$error`.
  final Object error;

  /// What this screen was asking for — 「它记住的」,「对话记录」,「任务」.
  ///
  /// Supplied by the screen because the Host deliberately does not name which of
  /// its internal services refused: the screen already knows what it asked for,
  /// and putting the Host's service graph in a public contract would tell a
  /// client something true and useless.
  final String subject;

  /// Null leaves no button rather than a disabled one. It is also ignored for a
  /// refusal that waiting cannot change, so a screen may pass its reload freely.
  final VoidCallback? onRetry;

  /// Kept so existing screens keep the keys their tests already look for.
  final Key? retryKey;

  @override
  Widget build(BuildContext context) {
    final offerRetry = onRetry != null && canRetry(error);
    final detail = refusalDetail(error);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            refusalText(error, subject: subject),
            textAlign: TextAlign.center,
          ),
          // The Host's own words, under this app's. Secondary because it is for
          // whoever owns the machine rather than for whoever is reading — and
          // present because on this product those are usually one person, and
          // dropping it is what left them with nothing to search for.
          if (detail != null) const SizedBox(height: 8),
          if (detail != null)
            Text(
              detail,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (offerRetry) const SizedBox(height: 16),
          if (offerRetry)
            OutlinedButton(
              key: retryKey,
              onPressed: onRetry,
              child: const Text('再试一次'),
            ),
        ],
      ),
    );
  }
}
