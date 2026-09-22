/// Finishing the network is not finishing the setup, and the product said it was.
///
/// A device that has just been provisioned and claimed still cannot be used:
/// its Owner has to say what it may present, and which Eidolon answers through
/// it. Both decisions already existed, in words that are already right — and
/// nothing took anyone to them. The last screen of provisioning drew a green
/// tick, said 设备已设置完成, and popped back to a list, while the device's own
/// screen said the service was not ready.
///
/// These pin the hand-off: what that screen is allowed to claim, which
/// decision is named first, and that a device nobody has finished is not
/// something you have to already know to go looking for.
library;

import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/device_management/mounted_devices_page.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MountedDevice _device({
  required String id,
  String state = 'awaiting_outputs',
  Map<String, dynamic> capabilities = const {
    'speech': true,
    'dialogue_text': true,
    'expression': true,
  },
  Map<String, dynamic>? allowed,
  String? companionId,
}) =>
    MountedDevice.fromView(
      DeviceView.fromJson({
        'device_id': 'device-instance-$id',
        'label': 'esp-box-3',
        'kind': 'esp-box-3',
        'state': state,
        if (companionId != null) 'answers_as_companion_id': companionId,
        'answers_as_companion_name': companionId == null ? '' : '小忆',
        'quiet_because': '',
        'revision': 4,
        'mount_revision': 7,
        'updated_at': '2026-09-18T09:05:05Z',
        'online': 'unknown',
        'online_reason': '',
        'claim_state': 'active',
        'claim_generation': 1,
        'trust_epoch': 1,
        'owner_domain_generation': 8,
        'manifest_id': 'esp-box-3',
        'manifest_revision': 1,
        'outputs': {
          'capabilities': capabilities,
          if (allowed != null) 'allowed': allowed,
          'revision': 0,
        },
      }),
    );

Future<void> _openDetail(WidgetTester tester, MountedDevice device) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MountedDeviceDetailPage(
        device: device,
        onRemove: (_, __) async => throw StateError('not this test'),
        onSetOutputs: ({
          required String deviceId,
          required OutputSelection allowed,
    InputSelection? inputs,
          required int expectedRevision,
        }) async {},
        onBindCompanion: ({
          required String deviceId,
          required String requestId,
          required String? companionId,
          required int expectedRevision,
        }) async {},
        loadCompanions: () async => throw StateError('not this test'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('which devices their Owner still has to finish', () {
    test('a device the Host will not serve is one of them, a ready one is not',
        () {
      final waiting = _device(id: 'a');
      final ready = _device(id: 'b', state: 'ready', allowed: const {
        'speech': true,
      }, companionId: 'c_01');

      expect(devicesAwaitingOwner([ready, waiting]), [waiting]);
      expect(devicesAwaitingOwner([ready]), isEmpty);
    });

    test('outputs come before a Companion, whatever order the Host listed them',
        () {
      final needsCompanion = _device(id: 'a', state: 'awaiting_companion');
      final needsOutputs = _device(id: 'b');

      expect(
        devicesAwaitingOwner([needsCompanion, needsOutputs]),
        [needsOutputs, needsCompanion],
      );
    });

    test('a device whose access is gone is not unfinished work', () {
      // Nothing its Owner decides brings it back; what is left is the unmount,
      // and offering to "finish setting it up" would be a lie of its own.
      final revoked = _device(id: 'a', state: 'access_revoked');

      expect(devicesAwaitingOwner([revoked]), isEmpty);
    });
  });

  group('the device that cannot be used yet says so first', () {
    testWidgets('it leads with why, and names the decision that unblocks it',
        (tester) async {
      await _openDetail(tester, _device(id: 'a'));

      final lead = find.byKey(const Key('device-unfinished-lead'));
      expect(lead, findsOneWidget);
      // The Owner's terms, not the device's: its screen already says "service
      // is not ready" and that is exactly the sentence nobody can act on.
      expect(
        tester.widget<Text>(find.descendant(of: lead, matching: find.byType(Text)).first).data,
        contains('还不能开始对话'),
      );
      expect(find.byKey(const Key('device-unfinished-action')), findsOneWidget);
    });

    testWidgets('the blocking decision is drawn above the other one',
        (tester) async {
      await _openDetail(tester, _device(id: 'a'));

      final outputs = tester.getTopLeft(find.byKey(const Key('device-outputs')));
      final companion =
          tester.getTopLeft(find.byKey(const Key('device-companion-binding')));
      expect(outputs.dy, lessThan(companion.dy));
    });

    testWidgets('a device with nothing left to decide leads with nothing',
        (tester) async {
      await _openDetail(
        tester,
        _device(
          id: 'a',
          state: 'ready',
          allowed: const {'speech': true},
          companionId: 'c_01',
        ),
      );

      expect(find.byKey(const Key('device-unfinished-lead')), findsNothing);
    });
  });

  group('deciding the outputs', () {
    testWidgets('allowing everything it declared is one tap, and allows no more',
        (tester) async {
      OutputSelection? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: MountedDeviceDetailPage(
            device: _device(
              id: 'a',
              // It never declared a body, so nothing may allow motion.
              capabilities: const {
                'speech': true,
                'expression': true,
              },
            ),
            onRemove: (_, __) async => throw StateError('not this test'),
            onSetOutputs: ({
              required String deviceId,
              required OutputSelection allowed,
    InputSelection? inputs,
              required int expectedRevision,
            }) async {
              saved = allowed;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('decide-device-outputs')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('device-outputs-allow-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device-outputs-save')));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.speech, isTrue);
      expect(saved!.expression, isTrue);
      expect(saved!.motion ?? false, isFalse);
      expect(saved!.audioCue ?? false, isFalse);
    });
  });
}
