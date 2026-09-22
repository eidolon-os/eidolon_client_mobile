/// What a device may present, decided by the person who owns it.
///
/// A Companion device cannot be served at all until this decision exists — the
/// Host refuses it a channel and the device's own screen says the service is
/// not ready — and there was no way in the product to make it. These pin the
/// screen that makes it, and the two sentences that must stay different:
/// nobody has decided, and somebody decided on nothing.
library;

import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/device_management/mounted_devices_page.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String _deviceId =
    'device-instance-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

MountedDevice _device({
  String state = 'awaiting_outputs',
  Map<String, dynamic>? allowed,
  int revision = 0,
  bool? microphoneCapability,
  bool? microphone,
}) =>
    MountedDevice.fromView(
      DeviceView.fromJson({
        'device_id': _deviceId,
        'label': 'esp-box-3',
        'kind': 'esp-box-3',
        'state': state,
        'answers_as_companion_id': 'c_01',
        'answers_as_companion_name': '小忆',
        'quiet_because': '',
        'revision': 4,
        'mount_revision': 7,
        'updated_at': '2026-09-17T08:10:00Z',
        'online': 'unknown',
        'online_reason': '这台主机没有任何东西在观测设备是否开着',
        'claim_state': 'active',
        'claim_generation': 2,
        'trust_epoch': 1,
        'owner_domain_generation': 3,
        'manifest_id': 'esp-box-3',
        'manifest_revision': 1,
        'outputs': {
          if (microphoneCapability != null) 'input_capabilities': {'microphone': microphoneCapability},
          if (microphone != null) 'inputs': {'microphone': microphone},
          // What this board declared: it can take audio, show the face and
          // show dialogue text. It never declared a body.
          'capabilities': {
            'speech': true,
            'dialogue_text': true,
            'expression': true,
          },
          if (allowed != null) 'allowed': allowed,
          'revision': revision,
        },
      }),
    );

Future<void> _open(
  WidgetTester tester,
  MountedDevice device, {
  Future<void> Function({
    required String deviceId,
    required OutputSelection allowed,
    InputSelection? inputs,
    required int expectedRevision,
  })? onSetOutputs,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MountedDeviceDetailPage(
        device: device,
        onRemove: (_, __) async => throw StateError('not this test'),
        onSetOutputs: onSetOutputs,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapWhereverItIs(WidgetTester tester, Key key) async {
  final control = find.byKey(key);
  if (control.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      control,
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('mounted-device-detail')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(control);
  await tester.pumpAndSettle();
  await tester.tap(control);
}

void main() {
  testWidgets('microphone choice is independent of speech and saved atomically', (tester) async {
    InputSelection? savedInputs;
    OutputSelection? savedOutputs;
    await _open(tester, _device(allowed: {'speech': true}, revision: 4,
        microphoneCapability: true, microphone: true), onSetOutputs: ({
      required String deviceId, required OutputSelection allowed,
      InputSelection? inputs, required int expectedRevision,
    }) async {
      expect(expectedRevision, 4);
      savedInputs = inputs;
      savedOutputs = allowed;
    });
    await _tapWhereverItIs(tester, const Key('decide-device-outputs'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-input-microphone')));
    await tester.ensureVisible(find.byKey(const Key('device-outputs-save')));
    await tester.tap(find.byKey(const Key('device-outputs-save')));
    await tester.pumpAndSettle();
    expect(savedInputs?.microphone, false);
    expect(savedOutputs?.speech, true);
  });

  testWidgets('a device without microphone capability has no input switch', (tester) async {
    await _open(tester, _device(microphoneCapability: false), onSetOutputs: ({
      required String deviceId, required OutputSelection allowed,
      InputSelection? inputs, required int expectedRevision,
    }) async {});
    await _tapWhereverItIs(tester, const Key('decide-device-outputs'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-input-microphone')), findsNothing);
  });

  testWidgets('a decision nobody has made is not shown as an empty one',
      (tester) async {
    await _open(tester, _device(), onSetOutputs: ({
      required String deviceId,
      required OutputSelection allowed,
    InputSelection? inputs,
      required int expectedRevision,
    }) async {});

    expect(
      find.text('还没有决定 —— 在定下来之前，主机不会让它开始对话'),
      findsOneWidget,
    );
    // The word on the control is the difference between making a decision and
    // revisiting one.
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('a device its Owner silenced says so in its own words',
      (tester) async {
    await _open(
      tester,
      _device(state: 'ready', allowed: const {}, revision: 3),
      onSetOutputs: ({
        required String deviceId,
        required OutputSelection allowed,
    InputSelection? inputs,
        required int expectedRevision,
      }) async {},
    );

    expect(find.text('你把它设成了什么都不表达'), findsOneWidget);
    expect(find.text('更改'), findsOneWidget);
  });

  testWidgets('only what the device declared can be allowed', (tester) async {
    await _open(tester, _device(), onSetOutputs: ({
      required String deviceId,
      required OutputSelection allowed,
    InputSelection? inputs,
      required int expectedRevision,
    }) async {});
    await _tapWhereverItIs(tester, const Key('decide-device-outputs'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('device-output-speech')), findsOneWidget);
    expect(find.byKey(const Key('device-output-expression')), findsOneWidget);
    expect(find.byKey(const Key('device-output-dialogue_text')), findsOneWidget);
    // Never declared, so never offered: allowing it would be a decision
    // nothing could carry out.
    expect(find.byKey(const Key('device-output-motion')), findsNothing);
    expect(find.byKey(const Key('device-output-audio_cue')), findsNothing);
  });

  testWidgets('the decision carries the revision the screen was showing',
      (tester) async {
    final decisions = <Map<String, Object?>>[];
    await _open(
      tester,
      _device(allowed: const {'expression': true}, revision: 2, state: 'ready'),
      onSetOutputs: ({
        required String deviceId,
        required OutputSelection allowed,
    InputSelection? inputs,
        required int expectedRevision,
      }) async {
        decisions.add({
          'device': deviceId,
          'allowed': allowed,
          'revision': expectedRevision,
        });
      },
    );
    await _tapWhereverItIs(tester, const Key('decide-device-outputs'));
    await tester.pumpAndSettle();
    // What was already allowed comes up chosen; this adds one to it.
    await tester.tap(find.byKey(const Key('device-output-dialogue_text')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-outputs-save')));
    await tester.pumpAndSettle();

    expect(decisions, hasLength(1));
    expect(decisions.single['device'], _deviceId);
    expect(decisions.single['revision'], 2);
    // What was chosen, and what was left off. An output this device never
    // declared is not named at all: absent means off by the contract's own
    // default, and naming it would be this screen deciding about a thing the
    // device does not have.
    final allowed = decisions.single['allowed']! as OutputSelection;
    expect(allowed.expression, isTrue);
    expect(allowed.dialogueText, isTrue);
    expect(allowed.speech, isFalse);
    expect(allowed.motion ?? false, isFalse);
    expect(allowed.audioCue ?? false, isFalse);
  });

  testWidgets('a Host that does not offer the decision draws no control',
      (tester) async {
    await _open(tester, _device());

    expect(find.byKey(const Key('device-outputs')), findsOneWidget);
    expect(find.byKey(const Key('decide-device-outputs')), findsNothing);
  });
}
