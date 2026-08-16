import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/device_management/mounted_devices_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MountedDevice _device({String displayName = ''}) => MountedDevice.fromJson({
  'device_id': 'esp32-0123456789abcdef',
  'display_name': displayName,
  'device_kind': 'esp32-box3',
  'admission_state': 'ready',
  'mount': {
    'revision': 2,
    'attached_companion_id': 'companion-1',
    'updated_at': '2026-08-12T08:10:00Z',
  },
});

Future<void> _open(
  WidgetTester tester, {
  required MountedDevice device,
  Future<void> Function(String deviceId, String displayName)? onRename,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MountedDeviceDetailPage(
        device: device,
        onRemove: (_) async => throw StateError('not part of this test'),
        onRename: onRename,
      ),
    ),
  );
}

void main() {
  testWidgets('the page is titled by the device, not by the screen', (
    tester,
  ) async {
    await _open(tester, device: _device(displayName: '客厅的 Box-3'));
    expect(find.text('客厅的 Box-3'), findsWidgets);
  });

  testWidgets('a nameless device offers what it is instead of its id', (
    tester,
  ) async {
    await _open(tester, device: _device());
    // Never the raw identifier as the headline: an Owner reads what the thing
    // is, and only then how the system happens to spell it.
    expect(find.text('esp32-box3'), findsWidgets);
  });

  testWidgets('renaming asks, then reports the chosen name once', (
    tester,
  ) async {
    final calls = <List<String>>[];
    await _open(
      tester,
      device: _device(displayName: 'esp32-box3'),
      onRename: (deviceId, displayName) async =>
          calls.add([deviceId, displayName]),
    );

    await tester.tap(find.byKey(const Key('rename-device')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('device-name-field')),
      '  客厅的音箱  ',
    );
    await tester.tap(find.byKey(const Key('confirm-device-name')));
    await tester.pumpAndSettle();

    // Trimmed, because trailing space is a typing accident and not a name.
    expect(calls, [
      ['esp32-0123456789abcdef', '客厅的音箱'],
    ]);
  });

  testWidgets('cancelling and clearing the box both mean leave it alone', (
    tester,
  ) async {
    var calls = 0;
    await _open(
      tester,
      device: _device(displayName: '客厅的音箱'),
      onRename: (_, __) async => calls += 1,
    );

    await tester.tap(find.byKey(const Key('rename-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(calls, 0);

    await tester.tap(find.byKey(const Key('rename-device')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('device-name-field')), '   ');
    await tester.tap(find.byKey(const Key('confirm-device-name')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.byKey(const Key('mounted-device-detail')), findsOneWidget);
  });

  testWidgets('a refused rename says so and keeps the device on screen', (
    tester,
  ) async {
    await _open(
      tester,
      device: _device(displayName: '客厅的音箱'),
      onRename: (_, __) async => throw StateError('主机暂时不可用'),
    );

    await tester.tap(find.byKey(const Key('rename-device')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('device-name-field')), '书房');
    await tester.tap(find.byKey(const Key('confirm-device-name')));
    await tester.pumpAndSettle();

    final notice = tester.widget<Text>(
      find.byKey(const Key('device-removal-notice')),
    );
    expect(notice.data, contains('改名没有完成'));
    expect(find.byKey(const Key('mounted-device-detail')), findsOneWidget);
  });

  testWidgets('a Host that cannot be told a name offers no rename', (
    tester,
  ) async {
    await _open(tester, device: _device(displayName: '客厅的音箱'));
    expect(find.byKey(const Key('rename-device')), findsNothing);
  });
}
