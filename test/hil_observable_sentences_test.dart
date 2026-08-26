import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The sentences an automated hardware run reads off this app's screens.
///
/// `eidolon_ops`' device-management baseline harness observes Owner-facing
/// facts the way an Owner does — by reading the phone — so a handful of this
/// app's own sentences are load-bearing outside this repository. An assertion
/// about what a person sees can only be written in the words they see, so the
/// harness necessarily holds a copy of them.
///
/// This test is the other half of that copy. Rewording one of these is allowed;
/// doing it silently is not, because the harness would simply stop observing
/// that step and the hardware gate would go quiet about it rather than red.
/// When this fails, change the sentence here and in
/// `eidolon_ops/src/eidolon_ops/device_baseline.py` together.
void main() {
  const observed = <String, String>{
    // step id -> the sentence the harness looks for
    'proposal_observed': '明确批准这次 Enrollment',
    'approval_recorded': '已批准，等待设备领取 Grant',
    'claim_active_observed': '已接入',
    'mount_active_observed': '挂载 revision',
    'platform_revoked_observed': '已失去访问',
    'erase_pending_observed': '尚未确认擦除',
  };

  const sources = <String>[
    'lib/src/features/device_setup/device_admission_page.dart',
    'lib/src/features/device_management/mounted_devices_page.dart',
  ];

  test('every sentence the hardware baseline reads is still on a screen', () {
    final haystack = sources.map((path) => File(path).readAsStringSync()).join('\n');

    final missing = <String>[];
    observed.forEach((step, sentence) {
      if (!haystack.contains(sentence)) {
        missing.add('$step: "$sentence"');
      }
    });

    expect(
      missing,
      isEmpty,
      reason:
          'These sentences are read by the device-management baseline harness in '
          'eidolon_ops. Rewording one is fine, but the harness has to be changed '
          'in the same breath or it stops observing that step: '
          '${missing.join('; ')}',
    );
  });
}
