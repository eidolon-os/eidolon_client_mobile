import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/device_management/mounted_devices_page.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MountedDevice device({Map<String, Object?>? presence}) =>
    MountedDevice.fromView(DeviceView.fromJson({
      'device_id': 'device-1',
      'label': 'Speaker',
      'state': 'ready',
      'claim_generation': 1,
      'claim_state': 'active',
      'mount_revision': 1,
      'owner_domain_generation': 1,
      'revision': 1,
      'trust_epoch': 1,
      'updated_at': '2026-10-10T00:00:00Z',
      'outputs': {'capabilities': <String, dynamic>{}, 'revision': 0},
      if (presence != null) 'presence': presence,
    }));

Map<String, Object?> observation(String state, DateTime at) => {
      'state': state,
      'source': 'channel',
      'observed_at': at.toIso8601String(),
      'valid_until': at.add(const Duration(seconds: 15)).toIso8601String(),
      'reason': '设备通道观测',
    };

void main() {
  final at = DateTime.utc(2026, 10, 10);

  test('old Hosts and admission alone cannot assert connectivity', () {
    final old = device();
    expect(old.state, MountedDeviceState.ready);
    expect(old.connectionStateAt(at), 'unknown');
  });

  test('online and offline expire without being converted into each other', () {
    for (final state in ['online', 'offline']) {
      final current = device(presence: observation(state, at));
      expect(current.connectionStateAt(at), state);
      expect(current.connectionStateAt(at.add(const Duration(seconds: 14))),
          state);
      expect(current.connectionStateAt(at.add(const Duration(seconds: 15))),
          'unknown');
      expect(current.connectionStateAt(at.subtract(const Duration(seconds: 1))),
          'unknown');
    }
  });

  test('unknown states and malformed timestamps fail to unknown', () {
    expect(device(presence: observation('new-state', at)).connectionStateAt(at),
        'unknown');
    expect(
        device(presence: {...observation('online', at), 'valid_until': 'bad'})
            .connectionStateAt(at),
        'unknown');
  });

  testWidgets('a refreshed observation changes the visible connection label',
      (tester) async {
    for (final entry
        in {'online': '在线', 'offline': '离线', 'unknown': '连接状态未知'}.entries) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: DeviceConnectionStatus(
                  device: device(
                      presence:
                          observation(entry.key, DateTime.now().toUtc()))))));
      expect(find.text(entry.value), findsOneWidget);
    }
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DeviceConnectionStatus(
                device: device(
                    presence: observation(
                        'online',
                        DateTime.now()
                            .toUtc()
                            .subtract(const Duration(minutes: 1))))))));
    expect(find.text('连接状态未知'), findsOneWidget);
    expect(find.text('在线'), findsNothing);
  });
}
