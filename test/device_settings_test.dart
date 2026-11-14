import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/device_management/device_settings_section.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _device = '10:51:db:7e:24:44:aa:bb:cc:dd:ee:ff:00:11';

void main() {
  test('a setting travels as one installed capability with the caller\'s id',
      () async {
    late http.Request seen;
    final client = ManagementClient(httpClient: MockClient((request) async {
      seen = request;
      return http.Response(
        jsonEncode({
          'device_id': _device,
          'capability': 'audio.volume.set',
          'state': 'completed',
          'result': {'volume': 30},
          'error': '',
        }),
        200,
      );
    }));

    final execution = await client.invokeDeviceCapability(
      Uri.parse('https://local.test'),
      accessToken: 'token',
      deviceId: _device,
      capability: 'audio.volume.set',
      arguments: {'volume': 30},
      requestId: 'gesture-1',
    );

    expect(seen.method, 'POST');
    expect(
      seen.url.path,
      '/api/management/v1/devices/${Uri.encodeComponent(_device)}'
      '/capabilities/audio.volume.set',
    );
    expect(seen.headers['Authorization'], 'Bearer token');
    expect(jsonDecode(seen.body), {
      'request_id': 'gesture-1',
      'arguments': {'volume': 30},
    });
    expect(execution.state, 'completed');
    expect(execution.result, {'volume': 30});
  });

  test('properties are read as the device reported them', () async {
    final client = ManagementClient(httpClient: MockClient((request) async {
      expect(request.url.path,
          '/api/management/v1/devices/${Uri.encodeComponent(_device)}/properties');
      return http.Response(
        jsonEncode({'device_id': _device, 'values': {'audio.volume': 25}}),
        200,
      );
    }));
    final view = await client.fetchDeviceProperties(
      Uri.parse('https://local.test'),
      accessToken: 'token',
      deviceId: _device,
    );
    expect(view.values, {'audio.volume': 25});
  });

  test('a refusal keeps the Host\'s reason', () async {
    final client = ManagementClient(httpClient: MockClient((request) async {
      return http.Response(
        jsonEncode({
          'detail': {
            'refusal': {
              'kind': 'conflict',
              'reason': 'device does not offer audio.volume.set',
              'code': 'CAPABILITY_NOT_OFFERED',
              'retryable': false,
            },
          },
        }),
        409,
      );
    }));
    await expectLater(
      client.invokeDeviceCapability(
        Uri.parse('https://local.test'),
        accessToken: 'token',
        deviceId: _device,
        capability: 'audio.volume.set',
        arguments: {'volume': 1},
        requestId: 'r',
      ),
      throwsA(isA<ManagementRequestException>()
          .having((e) => e.statusCode, 'statusCode', 409)),
    );
  });

  group('DeviceSettingsSection', () {
    late Map<String, Object?> reported;
    late List<Map<String, Object?>> writes;
    late String writeState;

    Future<DevicePropertiesView> read(String deviceId) async {
      expect(deviceId, _device);
      return DevicePropertiesView(deviceId: deviceId, values: Map.of(reported));
    }

    Future<DeviceCapabilityExecutionView> write({
      required String deviceId,
      required String capability,
      required Map<String, Object?> arguments,
      required String requestId,
    }) async {
      writes.add({
        'capability': capability,
        'arguments': arguments,
        'request_id': requestId,
      });
      final applied = (arguments.values.single as int).clamp(0, 80);
      return DeviceCapabilityExecutionView(
        deviceId: deviceId,
        capability: capability,
        state: writeState,
        result: writeState == 'completed' ? {arguments.keys.single: applied} : {},
        error: writeState == 'completed' ? '' : 'hardware_error',
      );
    }

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DeviceSettingsSection(
            deviceId: _device,
            read: read,
            write: write,
            pollInterval: const Duration(milliseconds: 100),
          ),
        ),
      ));
      await tester.pump();
    }

    setUp(() {
      reported = {};
      writes = [];
      writeState = 'completed';
    });

    testWidgets('draws only the settings the device reported', (tester) async {
      reported = {'audio.volume': 40};
      await pump(tester);
      expect(find.byKey(const Key('device-setting-audio.volume')), findsOneWidget);
      expect(find.byKey(const Key('device-setting-display.brightness')),
          findsNothing);

      reported = {};
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      expect(find.byKey(const Key('device-settings')), findsNothing);
    });

    testWidgets('sends the settled position and shows what the device applied',
        (tester) async {
      reported = {'audio.volume': 40};
      await pump(tester);

      final slider = find.byKey(const Key('device-setting-audio.volume'));
      await tester.drag(slider, const Offset(400, 0));
      await tester.pump();

      expect(writes, hasLength(1));
      expect(writes.single['capability'], 'audio.volume.set');
      final sent = (writes.single['arguments'] as Map)['volume'] as int;
      expect(sent, greaterThan(40));
      expect(writes.single['request_id'] as String,
          startsWith('audio.volume.set-'));
      // The device clamped to 80; the slider says what it applied.
      final shown = tester.widget<Slider>(slider).value.round();
      expect(shown, sent.clamp(0, 80));
    });

    testWidgets('a background read does not move a slider whose change is out',
        (tester) async {
      reported = {'audio.volume': 40};
      await pump(tester);
      final slider = find.byKey(const Key('device-setting-audio.volume'));
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      final dragged = tester.widget<Slider>(slider).value;

      reported = {'audio.volume': 5};
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      expect(tester.widget<Slider>(slider).value, dragged);
      await gesture.up();
      await tester.pump();
    });

    testWidgets('a device that did not apply the change says why',
        (tester) async {
      reported = {'audio.volume': 40};
      writeState = 'failed';
      await pump(tester);
      await tester.drag(find.byKey(const Key('device-setting-audio.volume')),
          const Offset(100, 0));
      await tester.pump();
      expect(find.byKey(const Key('device-settings-notice')), findsOneWidget);
      expect(find.textContaining('hardware_error'), findsOneWidget);
    });
  });
}
