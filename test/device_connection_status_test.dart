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
      'remaining_ms': 15000,
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
    expect(old.connectionState, 'unknown');
  });

  test(
      'freshness uses elapsed time, independent of Host and phone clock offset',
      () {
    for (final offset in [
      const Duration(milliseconds: 310),
      const Duration(days: 2),
      const Duration(days: -2)
    ]) {
      for (final state in ['online', 'offline']) {
        var elapsed = const Duration(milliseconds: 120);
        final lease = DevicePresenceLease(
          DevicePresenceView.fromJson(observation(state, at.add(offset))),
          elapsed: () => elapsed,
        );
        expect(lease.state, state);
        elapsed = const Duration(seconds: 14);
        expect(lease.state, state);
        elapsed = const Duration(seconds: 15);
        expect(lease.state, 'unknown');
      }
    }
  });

  test('transit time consumes freshness; old Hosts cannot grant a lease', () {
    final lease = DevicePresenceLease(
      DevicePresenceView(state: 'online', remainingMs: 1000),
      elapsed: () => const Duration(seconds: 2),
    );
    expect(lease.state, 'unknown');
    for (final ttl in [null, 0, -1, 15001]) {
      expect(
          DevicePresenceLease(
              DevicePresenceView(state: 'online', remainingMs: ttl),
              elapsed: () => Duration.zero).state,
          'unknown');
    }
    expect(
        DevicePresenceLease(
            DevicePresenceView(state: 'future-state', remainingMs: 1000),
            elapsed: () => Duration.zero).state,
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
                device: device(presence: {
      ...observation('online', DateTime.now()),
      'remaining_ms': 0
    })))));
    expect(find.text('连接状态未知'), findsOneWidget);
    expect(find.text('在线'), findsNothing);
  });
}
