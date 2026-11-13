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
import 'package:eidolon_client_mobile/src/management/management_client.dart';
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
  // What the device declared about its camera, and what its Owner chose.
  String? cameraCapability,
  String? camera,
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
          if (microphoneCapability != null || cameraCapability != null)
            'input_capabilities': {
              if (microphoneCapability != null)
                'microphone': microphoneCapability,
              if (cameraCapability != null) 'camera': cameraCapability,
            },
          if (microphone != null || camera != null)
            'inputs': {
              if (microphone != null) 'microphone': microphone,
              if (camera != null) 'camera': camera,
            },
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
    // The complete catalog is visible, but unimplemented outputs cannot be granted.
    for (final name in ['motion', 'audio_cue']) {
      final tile = tester.widget<SwitchListTile>(find.byKey(Key('device-output-$name')));
      expect(tile.onChanged, isNull);
      expect(tile.value, isFalse);
    }
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

  group('camera use', () {
    // A robot that declared the capture contract, already decided about.
    MountedDevice robot({String? camera, bool? microphone = true}) => _device(
          state: 'ready',
          allowed: const {'speech': true},
          revision: 4,
          microphoneCapability: true,
          microphone: microphone,
          cameraCapability: 'capture',
          camera: camera,
        );

    /// Opens the picker and returns what each save sent.
    Future<List<InputSelection?>> openPicker(
      WidgetTester tester,
      MountedDevice device, {
      Object? refuseWith,
    }) async {
      // Tall enough that the whole sheet is built: the camera adds three rows
      // and the sheet is a lazy list.
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sent = <InputSelection?>[];
      await _open(tester, device, onSetOutputs: ({
        required String deviceId,
        required OutputSelection allowed,
        InputSelection? inputs,
        required int expectedRevision,
      }) async {
        sent.add(inputs);
        if (refuseWith != null) throw refuseWith;
      });
      await _tapWhereverItIs(tester, const Key('decide-device-outputs'));
      await tester.pumpAndSettle();
      return sent;
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('device-outputs-save')));
      await tester.pumpAndSettle();
    }

    bool shownAsChosen(WidgetTester tester, String use) => find
        .descendant(
          of: find.byKey(Key('device-input-camera-$use')),
          matching: find.byIcon(Icons.radio_button_checked),
        )
        .evaluate()
        .isNotEmpty;

    testWidgets('is not offered, or sent, for a device with no camera',
        (tester) async {
      final sent = await openPicker(
        tester,
        _device(
          state: 'ready',
          allowed: const {'speech': true},
          microphoneCapability: true,
          microphone: true,
        ),
      );

      for (final use in ['off', 'local', 'capture']) {
        expect(find.byKey(Key('device-input-camera-$use')), findsNothing);
      }
      await save(tester);
      expect(sent.single?.camera, isNull);
      expect(sent.single?.toJson().containsKey('camera'), isFalse);
      expect(sent.single?.microphone, isTrue);
    });

    testWidgets('a choice nobody made shows as local, unchosen, and stays so',
        (tester) async {
      final device = robot();
      final sent = await openPicker(tester, device);

      // Behind the sheet, the device's own row says the same thing.
      expect(find.textContaining('摄像头仅本地（尚未选择）'), findsOneWidget);
      expect(shownAsChosen(tester, 'local'), isTrue);
      expect(shownAsChosen(tester, 'off'), isFalse);
      expect(shownAsChosen(tester, 'capture'), isFalse);
      expect(
        find.byKey(const Key('device-input-camera-undecided')),
        findsOneWidget,
      );

      // Opening and saving is not choosing: the request leaves the camera out,
      // which the Host reads as "keep what is there".
      await save(tester);
      expect(sent.single?.camera, isNull);
      expect(sent.single?.microphone, isTrue);
    });

    testWidgets('picking local where nothing was chosen writes local',
        (tester) async {
      final sent = await openPicker(tester, robot());

      await tester.tap(find.byKey(const Key('device-input-camera-local')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('device-input-camera-undecided')),
        findsNothing,
      );
      expect(find.byKey(const Key('confirm-device-camera-capture')), findsNothing);

      await save(tester);
      expect(sent.single?.camera, 'local');
      expect(sent.single?.microphone, isTrue);
    });

    testWidgets('capture is asked about once more, and declining changes nothing',
        (tester) async {
      final sent = await openPicker(tester, robot(camera: 'local'));

      await tester.tap(find.byKey(const Key('device-input-camera-capture')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('confirm-device-camera-capture')),
        findsOneWidget,
      );
      // The three things the Owner is agreeing to.
      expect(find.textContaining('照片会离开这台设备，传到主机'), findsOneWidget);
      expect(find.textContaining('第三方模型，取决于主机的配置'), findsOneWidget);
      expect(find.textContaining('睡着的时候拍不到'), findsOneWidget);

      await tester.tap(find.text('暂不允许'));
      await tester.pumpAndSettle();
      expect(shownAsChosen(tester, 'capture'), isFalse);
      expect(shownAsChosen(tester, 'local'), isTrue);

      await save(tester);
      expect(sent.single?.camera, isNull);
    });

    testWidgets('capture confirmed is written with the microphone left as it was',
        (tester) async {
      final sent =
          await openPicker(tester, robot(camera: 'local', microphone: false));

      await tester.tap(find.byKey(const Key('device-input-camera-capture')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const Key('confirm-device-camera-capture-allow')));
      await tester.pumpAndSettle();
      expect(shownAsChosen(tester, 'capture'), isTrue);

      await save(tester);
      expect(sent.single?.camera, 'capture');
      expect(sent.single?.microphone, isFalse);
    });

    testWidgets('narrowing from capture needs no second question',
        (tester) async {
      final sent = await openPicker(tester, robot(camera: 'capture'));

      expect(find.textContaining('摄像头可拍照'), findsOneWidget);
      expect(shownAsChosen(tester, 'capture'), isTrue);
      await tester.tap(find.byKey(const Key('device-input-camera-off')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm-device-camera-capture')), findsNothing);
      expect(shownAsChosen(tester, 'off'), isTrue);

      await save(tester);
      expect(sent.single?.camera, 'off');
    });

    testWidgets('allowing everything does not reach the camera',
        (tester) async {
      final sent = await openPicker(tester, robot(camera: 'local'));

      await tester.tap(find.byKey(const Key('device-outputs-allow-all')));
      await tester.pumpAndSettle();
      expect(shownAsChosen(tester, 'local'), isTrue);

      await save(tester);
      expect(sent.single?.camera, isNull);
    });

    testWidgets('a use the Host refuses is said, and can be chosen again',
        (tester) async {
      // What the Hub answers when the device never declared a camera.
      final sent = await openPicker(
        tester,
        robot(),
        refuseWith: const ManagementRequestException(
          'refused',
          statusCode: 422,
          refusal: Refusal(
            kind: 'invalid',
            reason: 'device did not declare camera use',
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('device-input-camera-off')));
      await tester.pumpAndSettle();
      await save(tester);

      expect(sent.single?.camera, 'off');
      expect(find.byKey(const Key('mounted-device-detail')), findsOneWidget);
      final notice = tester.widget<Text>(
        find.byKey(const Key('device-removal-notice'), skipOffstage: false),
      );
      expect(notice.data, contains('主机没有接受这次设置'));
      expect(notice.data, contains('摄像头'));

      // The refused decision is not kept as something to resume: asking again
      // opens the choices rather than resending what was just refused.
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await _tapWhereverItIs(tester, const Key('decide-device-outputs'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device-outputs-picker')), findsOneWidget);
      expect(sent, hasLength(1));
    });
  });
}
