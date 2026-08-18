import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/device_management/mounted_devices_page.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MountedDevice _device() => MountedDevice.fromJson({
      'device_id': 'mobile-android-0123456789abcdef',
      'admission_state': 'ready',
      'mount': {
        'revision': 2,
        'attached_companion_id': 'companion-1',
        'updated_at': '2026-08-12T08:10:00Z',
      },
    });

DeviceRemovalProgress _progress(String outcome) =>
    DeviceRemovalProgress.fromJson({
      'operation': 'local.device-removal-progress',
      'contract_version': '1',
      'request_id': 'device-removal-1',
      'device_id': 'mobile-android-0123456789abcdef',
      'owner_id': 'owner-1',
      'outcome': outcome,
      'stopped_after':
          outcome == 'done' ? 'kernel-unmounted' : 'hub-revoked',
    });

Future<void> _open(
  WidgetTester tester,
  Future<DeviceRemovalProgress> Function(String deviceId) onRemove,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MountedDeviceDetailPage(device: _device(), onRemove: onRemove),
    ),
  );
}

void main() {
  testWidgets('removal needs an explicit confirmation', (tester) async {
    var calls = 0;
    await _open(tester, (_) async {
      calls += 1;
      return _progress('done');
    });

    await tester.tap(find.byKey(const Key('remove-mounted-device')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('confirm-device-removal')), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.byKey(const Key('mounted-device-detail')), findsOneWidget);
  });

  testWidgets('a confirmed removal leaves the detail page', (tester) async {
    String? removed;
    await _open(tester, (deviceId) async {
      removed = deviceId;
      return _progress('done');
    });

    await tester.tap(find.byKey(const Key('remove-mounted-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-device-removal-action')));
    await tester.pumpAndSettle();

    expect(removed, 'mobile-android-0123456789abcdef');
  });

  testWidgets('a revoked-but-still-mounted device says so', (tester) async {
    await _open(tester, (_) async => _progress('unfinished'));

    await tester.tap(find.byKey(const Key('remove-mounted-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-device-removal-action')));
    await tester.pumpAndSettle();

    final notice = tester.widget<Text>(
      find.byKey(const Key('device-removal-notice')),
    );
    expect(notice.data, contains('授权已撤销'));
    expect(find.byKey(const Key('mounted-device-detail')), findsOneWidget);
  });

  testWidgets('a failed removal keeps the device on screen', (tester) async {
    await _open(tester, (_) async => throw StateError('主机暂时不可用'));

    await tester.tap(find.byKey(const Key('remove-mounted-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-device-removal-action')));
    await tester.pumpAndSettle();

    final notice = tester.widget<Text>(
      find.byKey(const Key('device-removal-notice')),
    );
    expect(notice.data, contains('移除未完成'));
  });


  testWidgets('a refusal is not offered as something to retry', (tester) async {
    await _open(tester, (_) async => _progress('refused'));

    await tester.tap(find.byKey(const Key('remove-mounted-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-device-removal-action')));
    await tester.pumpAndSettle();

    final notice = tester.widget<Text>(
      find.byKey(const Key('device-removal-notice')),
    );
    // The Host decided. "Try again" would be offering something that can only
    // fail the same way — which is the distinction the three old fields made a
    // screen reassemble for itself.
    expect(notice.data, contains('拒绝'));
    expect(notice.data, isNot(contains('再试一次')));
  });
}
