import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/device_management/mounted_devices_page.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:flutter/material.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:flutter_test/flutter_test.dart';

MountedDevice _device({String state = 'ready'}) => MountedDevice.fromView(
      DeviceView.fromJson({
        'device_id': 'mobile-android-0123456789abcdef',
        'label': 'mobile-android',
        'kind': 'mobile-android',
        'state': state,
        'answers_as_companion_id': 'companion-1',
        'answers_as_companion_name': '小忆',
        'revision': 2,
        'updated_at': '2026-08-12T08:10:00Z',
        'online': 'unknown',
        'online_reason': '这台主机没有任何东西在观测设备是否开着',
        'claim_state': state == 'access_revoked' ? 'revoked' : 'active',
        'claim_generation': 1,
        'trust_epoch': 1,
        'owner_domain_generation': 3,
        'manifest_id': 'mobile-android',
        'manifest_revision': 1,
      }),
    );

DeviceRemovalProgress _progress(String outcome) =>
    DeviceRemovalProgress.fromView(
      DeviceRemovalView.fromJson({
        'contract_version': '1',
        'device_id': 'mobile-android-0123456789abcdef',
        'request_id': 'device-removal-1',
        'outcome': outcome,
        'conditions': [
          {
            'name': 'platform_access_revoked',
            'state': outcome == 'refused' ? 'false' : 'true',
            'authority': 'hub',
            'observed_at': '2026-08-23T10:00:00Z',
          },
          {
            'name': 'mount_removed',
            'state': outcome == 'done' ? 'true' : 'false',
            'authority': 'kernel',
            'observed_at': '2026-08-23T10:00:00Z',
          },
          {
            // Nobody has looked. Not the same as "no", which is the whole
            // reason these are conditions and not a percentage.
            'name': 'device_erase_acknowledged',
            'state': 'unknown',
            'authority': 'device-control',
            'observed_at': '',
          },
        ],
      }),
    );

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
