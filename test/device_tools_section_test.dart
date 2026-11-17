import 'package:eidolon_client_mobile/src/features/device_management/mounted_devices_page.dart';
import 'package:eidolon_client_mobile/src/features/tools/device_tools_section.dart';
import 'package:eidolon_client_mobile/src/features/tools/tool_policies.dart';
import 'package:eidolon_client_mobile/src/features/tools/tools_wording.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/tool_fixtures.dart';

/// 「{伙伴} 在这台设备上能用」: what a conversation on this device could use,
/// why not the rest, and the way to the one switch that changes each reason.

const _device = 'device-1';

FakeToolPolicies _host(DeviceToolsView view) =>
    FakeToolPolicies(devices: {_device: view});

final _mixed = deviceTools(_device, tools: [
  deviceRow('get_time'),
  deviceRow('music.play'),
  deviceRow('motion.nod', reasons: ['output_not_allowed:motion']),
  deviceRow('vision.look', reasons: [
    'input_not_allowed:camera',
    'host_not_configured:vision_model'
  ]),
  deviceRow('get_weather', reasons: ['global_off', 'companion_off']),
  deviceRow('motion.look', reasons: ['companion_off']),
  deviceRow('audio.volume.set', reasons: ['body_control_off']),
  deviceRow('weird.tool', reasons: ['device_not_declared:weird.tool']),
]);

Future<void> _open(WidgetTester tester, FakeToolPolicies tools,
    {void Function()? onOutputs}) async {
  await tester.binding.setSurfaceSize(const Size(800, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: NotificationListener<DeviceOutputsRequested>(
        onNotification: (_) {
          onOutputs?.call();
          return true;
        },
        child: ListView(children: [
          DeviceToolsSection(
            deviceId: _device,
            tools: tools,
            companionName: '小忆',
            devices: [mountedDevice(_device)],
          ),
        ]),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _unfold(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('device-tools-unavailable')));
  await tester.pumpAndSettle();
}

String _reason(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key('device-tool-reason-$key'))).data!;

void main() {
  test('every reason the Host gives reads as a sentence', () {
    const expected = {
      'reserved': '系统保留：语音对话中不开放',
      'global_off': '已在工具总览中关闭',
      'companion_off': '这个伙伴关掉了它',
      'body_control_off': '已关闭操控身体',
      'no_companion': '还没有伙伴通过这台设备应答',
      'channel_not_ready': '这台设备还不能开始对话',
      'device_not_declared:motion.nod': '这台设备没有这项能力',
      'device_not_declared:camera.capture': '这台设备没有可拍照的摄像头',
      'output_not_allowed:motion': '这台设备没允许做动作',
      'output_not_allowed:speech': '这台设备没允许说话',
      'output_not_allowed:expression': '这台设备没允许做表情',
      'input_not_allowed:camera': '这台设备的摄像头没有设为可拍照',
      'motion_profile_mismatch': '这台设备的身体做不了这种动作',
      'host_not_configured:vision_model': '主机还没配置视觉模型',
      'host_not_configured:music': '主机还没配置音乐服务',
      'host_not_configured:face_recognition': '主机还没配置人脸识别',
      'device_restricted': '在这台设备上被禁止了',
      // A Host newer than this phone still gets a sentence.
      'something_new': '暂时用不了',
    };
    for (final MapEntry(:key, :value) in expected.entries) {
      expect(toolReasonText(key), value, reason: key);
    }
    expect(toolHostRequirementText('music'), '需要主机已配置音乐服务');
  });

  test('a reason is matched to the one place that changes it', () {
    expect(toolReasonAction('output_not_allowed:motion'),
        ToolReasonAction.outputs);
    expect(
        toolReasonAction('input_not_allowed:camera'), ToolReasonAction.outputs);
    expect(toolReasonAction('companion_off'), ToolReasonAction.companion);
    expect(toolReasonAction('body_control_off'), ToolReasonAction.companion);
    expect(toolReasonAction('global_off'), ToolReasonAction.overview);
    for (final nothing in [
      'reserved',
      'no_companion',
      'channel_not_ready',
      'device_not_declared:motion.nod',
      'motion_profile_mismatch',
      'host_not_configured:music',
    ]) {
      expect(toolReasonAction(nothing), isNull, reason: nothing);
    }
  });

  testWidgets('what it can use is shown, the rest folded with the first reason',
      (tester) async {
    await _open(tester, _host(_mixed));

    expect(find.text('小忆 在这台设备上能用'), findsOneWidget);
    expect(find.byKey(const Key('device-tool-get_time')), findsOneWidget);
    // What the Host must have is a requirement, said where it is used.
    expect(
        find.descendant(
            of: find.byKey(const Key('device-tool-music.play')),
            matching: find.text('需要主机已配置音乐服务')),
        findsOneWidget);
    // Folded until asked for.
    expect(find.text('用不了的（6）'), findsOneWidget);
    expect(find.byKey(const Key('device-tool-motion.nod')), findsNothing);

    await _unfold(tester);
    expect(_reason(tester, 'motion.nod'), '这台设备没允许做动作');
    expect(_reason(tester, 'vision.look'), '这台设备的摄像头没有设为可拍照');
    // The first reason, not every one.
    expect(_reason(tester, 'get_weather'), '已在工具总览中关闭');
    expect(_reason(tester, 'weird.tool'), '这台设备没有这项能力');
    expect(
        find.byKey(const Key('device-tool-action-weird.tool')), findsNothing);
  });

  testWidgets('an output or camera reason asks the page for its outputs choice',
      (tester) async {
    var asked = 0;
    await _open(tester, _host(_mixed), onOutputs: () => asked++);
    await _unfold(tester);

    await tester.tap(find.byKey(const Key('device-tool-action-motion.nod')));
    await tester.pumpAndSettle();
    expect(asked, 1);
    expect(find.text('去设置'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('device-tool-action-vision.look')));
    await tester.pumpAndSettle();
    expect(asked, 2);
  });

  testWidgets('the device page answers that by opening its outputs picker',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final device = mountedDevice(_device);
    await tester.pumpWidget(MaterialApp(
      home: MountedDeviceDetailPage(
        device: device,
        onRemove: (_, __) async => throw StateError('not this test'),
        onSetOutputs: ({
          required String deviceId,
          required OutputSelection allowed,
          InputSelection? inputs,
          required int expectedRevision,
        }) async {},
        tools: DeviceToolsSection(
            deviceId: _device, tools: _host(_mixed), companionName: '小忆'),
      ),
    ));
    await tester.pumpAndSettle();

    final unfold = find.byKey(const Key('device-tools-unavailable'));
    await tester.ensureVisible(unfold);
    await tester.tap(unfold);
    await tester.pumpAndSettle();
    final action = find.byKey(const Key('device-tool-action-motion.nod'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('device-outputs-picker')), findsOneWidget);
  });

  testWidgets('its own switch being off opens its own page', (tester) async {
    final tools = _host(_mixed);
    await _open(tester, tools);
    await _unfold(tester);

    await tester.tap(find.byKey(const Key('device-tool-action-motion.look')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('companion-tools-page')), findsOneWidget);
    expect(find.text('小忆能做的事'), findsOneWidget);
    expect(tools.reads('companion $companionA'), 1);

    // And the section reads again on the way back.
    final reads = tools.reads('device $_device');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tools.reads('device $_device'), reads + 1);

    // 「允许操控身体」 lives on the same page.
    await _unfold(tester);
    await tester
        .tap(find.byKey(const Key('device-tool-action-audio.volume.set')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('companion-tools-page')), findsOneWidget);
  });

  testWidgets('a tool the Owner turned off opens the overview', (tester) async {
    await _open(tester, _host(_mixed));
    await _unfold(tester);

    await tester.tap(find.byKey(const Key('device-tool-action-get_weather')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tools-overview-page')), findsOneWidget);
  });

  testWidgets('a device nobody answers through says so, and lists nothing',
      (tester) async {
    await _open(
        tester,
        _host(deviceTools(_device, companionId: null, tools: [
          deviceRow('get_time', reasons: ['no_companion']),
        ])));

    expect(find.text('还没有伙伴'), findsOneWidget);
    expect(find.text('在这台设备上能用的工具'), findsOneWidget);
    expect(find.byKey(const Key('device-tools-unavailable')), findsNothing);
  });

  testWidgets('a section that could not read says so and offers a retry',
      (tester) async {
    final tools = _host(_mixed)..deviceFailure = toolPolicyChanged;
    await _open(tester, tools);
    expect(find.byKey(const Key('device-tools-failure')), findsOneWidget);

    tools.deviceFailure = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-tool-get_time')), findsOneWidget);
  });
}
