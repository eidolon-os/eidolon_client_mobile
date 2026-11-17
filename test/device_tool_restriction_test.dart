import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/device_management/mounted_devices_page.dart';
import 'package:eidolon_client_mobile/src/features/tools/device_tools_section.dart';
import 'package:eidolon_client_mobile/src/features/tools/tool_policies.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/tool_fixtures.dart';

/// 「在这台设备上禁止」: a device that never offers some tools, whoever answers
/// through it (§6). It only narrows, takes effect at once by ending the
/// conversation the device is holding, and is written as one whole list.

const _device = 'device-1';

final _tools = [
  deviceRow('get_time'),
  deviceRow('get_weather'),
  deviceRow('music.play', reasons: ['output_not_allowed:speech']),
  deviceRow('emit_event', reasons: ['reserved']),
];

FakeToolPolicies _host({DeviceToolRestriction? restricted}) =>
    FakeToolPolicies(devices: {
      _device: deviceTools(_device, tools: _tools, restriction: restricted)
    });

Future<void> _open(WidgetTester tester, FakeToolPolicies tools,
    {bool canRestrict = true, void Function()? onOutputs}) async {
  // A phone's width: the switch and its words have to fit beside a tool.
  await tester.binding.setSurfaceSize(const Size(375, 1600));
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
            canRestrict: canRestrict,
          ),
        ]),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('device-tools-unavailable')));
  await tester.pumpAndSettle();
}

Finder _restrict(String key) => find.byKey(Key('device-tool-restrict-$key'));

ManagementContextView _context(Map<String, bool> capabilities) =>
    ManagementContextView.fromJson({
      'contract_version': '1',
      'owner': {'owner_id': 'owner-1', 'display_name': 'Manson', 'revision': 1},
      'default_companion_id': companionA,
      'capabilities': capabilities,
      'unavailable': <String, String>{},
      'limits': {'max_active_companions': null},
    });

void main() {
  testWidgets('a switch sends the whole new list, against the revision shown',
      (tester) async {
    final tools = _host(restricted: restriction(4, ['music.play']));
    await _open(tester, tools);

    expect(find.text('在这台设备上禁止'), findsNWidgets(3));
    expect(tester.widget<Switch>(_restrict('music.play')).value, isTrue);
    expect(tester.widget<Switch>(_restrict('get_weather')).value, isFalse);

    await tester.tap(_restrict('get_weather'));
    await tester.pumpAndSettle();

    final (device, request) = tools.restrictions.single;
    expect(device, _device);
    expect(request.expectedRevision, 4);
    // The whole list, not a change: what was denied stays denied.
    expect(request.denied, ['get_weather', 'music.play']);
    expect(find.text('已生效；这台设备正在进行的对话会被结束，下一次对话起带上限制'), findsOneWidget);
    // Read again: the reason is the Host's, not this screen's.
    expect(tester.widget<Switch>(_restrict('get_weather')).value, isTrue);
    expect(
        tester
            .widget<Text>(
                find.byKey(const Key('device-tool-reason-get_weather')))
            .data,
        '在这台设备上被禁止了');

    // And lifted again, against the revision the Host answered.
    await tester.tap(_restrict('music.play'));
    await tester.pumpAndSettle();
    expect(tools.restrictions.last.$2.expectedRevision, 5);
    expect(tools.restrictions.last.$2.denied, ['get_weather']);
  });

  testWidgets('a device never restricted is at revision 0', (tester) async {
    final tools = _host();
    await _open(tester, tools);

    await tester.tap(_restrict('get_time'));
    await tester.pumpAndSettle();

    expect(tools.restrictions.single.$2.expectedRevision, 0);
    expect(tools.restrictions.single.$2.denied, ['get_time']);
  });

  testWidgets('a device whose outputs were never decided asks for them first',
      (tester) async {
    var asked = 0;
    final tools = _host()..writeFailure = outputPolicyRequired;
    await _open(tester, tools, onOutputs: () => asked++);

    await tester.tap(_restrict('get_time'));
    await tester.pumpAndSettle();

    expect(asked, 1);
    expect(find.text('先决定这台设备可以听和表达什么，再来限制它的工具'), findsOneWidget);
    expect(tester.widget<Switch>(_restrict('get_time')).value, isFalse);
  });

  testWidgets('…which the device page answers with its outputs picker',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: MountedDeviceDetailPage(
        device: mountedDevice(_device),
        onRemove: (_, __) async => throw StateError('not this test'),
        onSetOutputs: ({
          required String deviceId,
          required OutputSelection allowed,
          InputSelection? inputs,
          required int expectedRevision,
        }) async {},
        tools: DeviceToolsSection(
            deviceId: _device,
            tools: _host()..writeFailure = outputPolicyRequired,
            canRestrict: true),
      ),
    ));
    await tester.pumpAndSettle();

    final control = _restrict('get_time');
    await tester.ensureVisible(control);
    await tester.tap(control);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('device-outputs-picker')), findsOneWidget);
  });

  testWidgets('somebody else changing it first rereads instead of overwriting',
      (tester) async {
    final tools = _host(restricted: restriction(2, ['get_weather']))
      ..writeFailure = restrictionChanged;
    await _open(tester, tools);
    final reads = tools.reads('device $_device');

    await tester.tap(_restrict('get_time'));
    await tester.pumpAndSettle();

    expect(tools.reads('device $_device'), reads + 1);
    expect(find.text('这台设备的工具限制刚被改过，已经重新读取'), findsOneWidget);
    expect(tools.restrictions, hasLength(1));
    expect(tester.widget<Switch>(_restrict('get_time')).value, isFalse);
  });

  testWidgets('reserved tools have no switch to restrict', (tester) async {
    await _open(tester, _host());

    expect(find.byKey(const Key('device-tool-emit_event')), findsOneWidget);
    expect(_restrict('emit_event'), findsNothing);
    expect(_restrict('get_time'), findsOneWidget);
  });

  testWidgets('read-only where the Host does not offer restrictions',
      (tester) async {
    await _open(
        tester,
        FakeToolPolicies(devices: {
          _device: deviceTools(_device,
              restriction: restriction(1, ['get_weather']),
              tools: [
                ..._tools.where((row) => row.key != 'get_weather'),
                deviceRow('get_weather', reasons: ['device_restricted']),
              ]),
        }),
        canRestrict: false);

    expect(find.text('在这台设备上禁止'), findsNothing);
    expect(find.byType(Switch), findsNothing);
    // What is restricted is still said.
    expect(
        tester
            .widget<Text>(
                find.byKey(const Key('device-tool-reason-get_weather')))
            .data,
        '在这台设备上被禁止了');
  });

  test('editing is offered only on the Host\'s own word', () {
    expect(hostOffersDeviceToolRestriction(null), isFalse);
    expect(
        hostOffersDeviceToolRestriction(
            _context({'device.tool_restriction': true})),
        isTrue);
    expect(
        hostOffersDeviceToolRestriction(
            _context({'device.tool_restriction': false, 'tools.govern': true})),
        isFalse);
    expect(hostOffersDeviceToolRestriction(_context({'tools.govern': true})),
        isFalse);
  });

  test('the whole list travels on the generated path, never a device ref',
      () async {
    late http.Request seen;
    final client = ManagementClient(httpClient: MockClient((request) async {
      seen = request;
      return http.Response.bytes(
          utf8.encode(jsonEncode({
            'revision': 3,
            'denied': ['get_weather', 'music.play'],
          })),
          200);
    }));

    final answer = await client.changeDeviceToolRestriction(
        Uri.parse('https://local.test'),
        accessToken: 't',
        deviceId: _device,
        request: const DeviceToolRestrictionRequest(
            expectedRevision: 2, denied: ['music.play', 'get_weather']));

    expect(seen.method, 'PUT');
    expect(
        seen.url.path, '/api/management/v1/devices/$_device/tool-restriction');
    expect(jsonDecode(seen.body), {
      'expected_revision': 2,
      'denied': ['music.play', 'get_weather'],
    });
    expect(answer.revision, 3);
    expect(answer.denied, ['get_weather', 'music.play']);

    // Lifting every restriction is an empty list, not an absent one.
    await client.changeDeviceToolRestriction(Uri.parse('https://local.test'),
        accessToken: 't',
        deviceId: _device,
        request: const DeviceToolRestrictionRequest(
            expectedRevision: 3, denied: []));
    expect(jsonDecode(seen.body), {'expected_revision': 3, 'denied': []});
  });
}
