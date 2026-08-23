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
      'intent_id': 'removal-intent-1',
      'outcome': outcome,
      'conditions': [
        {
          'name': 'platform_access_revoked',
          'state': outcome == 'refused' ? 'false' : 'true',
          'authority': 'hub',
          'authority_ref': 'claim-event-1',
          'observed_at': '2026-08-23T10:00:00Z',
        },
        {
          'name': 'mount_removed',
          'state': outcome == 'done' ? 'true' : 'false',
          'authority': 'kernel',
          'authority_ref': null,
          'observed_at': '2026-08-23T10:00:00Z',
        },
        {
          'name': 'channel_access_revoked',
          'state': outcome == 'done' ? 'true' : 'unknown',
          'authority': 'device-control',
          'authority_ref': null,
          'observed_at': '2026-08-23T10:00:00Z',
        },
        {
          'name': 'device_erase_acknowledged',
          'state': 'unknown',
          'authority': 'device-control',
          'authority_ref': null,
          'observed_at': '2026-08-23T10:00:00Z',
        },
      ],
    });

Future<void> _open(
  WidgetTester tester,
  Future<DeviceRemovalProgress> Function(String deviceId, String requestId)
      onRemove,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MountedDeviceDetailPage(device: _device(), onRemove: onRemove),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('removal needs an explicit confirmation', (tester) async {
    var calls = 0;
    await _open(tester, (_, __) async {
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

  testWidgets('a confirmed platform removal does not claim local erase', (
    tester,
  ) async {
    String? removed;
    await _open(tester, (deviceId, _) async {
      removed = deviceId;
      return _progress('done');
    });

    await tester.tap(find.byKey(const Key('remove-mounted-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-device-removal-action')));
    await tester.pumpAndSettle();

    expect(removed, 'mobile-android-0123456789abcdef');
    expect(find.byKey(const Key('mounted-device-detail')), findsOneWidget);
    expect(find.textContaining('设备本地擦除尚未确认'), findsOneWidget);
  });

  testWidgets('a revoked-but-still-mounted device says so', (tester) async {
    await _open(tester, (_, __) async => _progress('unfinished'));

    await tester.tap(find.byKey(const Key('remove-mounted-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-device-removal-action')));
    await tester.pumpAndSettle();

    final notice = tester.widget<Text>(
      find.byKey(const Key('device-removal-notice')),
    );
    expect(notice.data, contains('平台访问授权已撤销'));
    expect(notice.data, contains('授权已撤销'));
    expect(find.byKey(const Key('mounted-device-detail')), findsOneWidget);
  });

  testWidgets('a failed removal keeps the device on screen', (tester) async {
    await _open(
      tester,
      (_, __) async => throw StateError('主机暂时不可用'),
    );

    await tester.tap(find.byKey(const Key('remove-mounted-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-device-removal-action')));
    await tester.pumpAndSettle();

    final notice = tester.widget<Text>(
      find.byKey(const Key('device-removal-notice')),
    );
    expect(notice.data, contains('继续同一移除意图'));
  });

  testWidgets('a refusal is not offered as something to retry', (tester) async {
    await _open(tester, (_, __) async => _progress('refused'));

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

  testWidgets('an unfinished retry keeps one removal intent id',
      (tester) async {
    final requestIds = <String>[];
    await _open(tester, (_, requestId) async {
      requestIds.add(requestId);
      return _progress('unfinished');
    });

    await tester.tap(find.byKey(const Key('remove-mounted-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-device-removal-action')));
    await tester.pumpAndSettle();
    expect(requestIds, hasLength(1));
    expect(find.byKey(const Key('mounted-device-detail')), findsOneWidget);

    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remove-mounted-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-device-removal-action')));
    await tester.pumpAndSettle();

    expect(requestIds, hasLength(2));
    expect(requestIds.toSet(), hasLength(1));
    expect(
      requestIds.first,
      matches(RegExp(r'^device-removal-[0-9a-f-]{36}$')),
    );
  });
}
