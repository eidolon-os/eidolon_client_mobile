import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/device_management/mounted_devices_page.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A mounted device answers as somebody, or as nobody. Until this screen could
/// say which, every device this product added arrived correct and unusable:
/// mounted, claimed, and bound to no Companion, with no way forward.

MountedDevice _device({String? companionId, int revision = 1}) =>
    MountedDevice.fromJson(<String, dynamic>{
      'claim': <String, dynamic>{
        'device_ref': <String, dynamic>{
          'device_instance_id': 'device-instance-${'c' * 64}',
          'owner_domain_id': 'owner-b0a862b0aab941d64554',
          'owner_domain_generation': 3,
          'claim_generation': 2,
          'trust_epoch': 1,
        },
        'business_owner_id': 'owner_683f0000000000000000',
        'manifest_ref': <String, dynamic>{
          'manifest_id': 'box3-device-manifest',
          'revision': 1,
          'digest': 'sha256:${'a' * 64}',
        },
        'state': 'active',
        'revision': 1,
        'updated_at': '2026-08-25T00:00:00Z',
      },
      'mount': <String, dynamic>{
        'revision': revision,
        'attached_companion_id': companionId,
        'updated_at': '2026-08-25T08:10:00Z',
      },
    });

CompanionRosterView _roster() => CompanionRosterView.fromJson({
      'contract_version': '1',
      'default_companion_id': 'c_01',
      'companions': [
        {
          'companion_id': 'c_01',
          'display_name': '曼森的 Eidolon',
          'kind': 'standard',
          'lifecycle_state': 'active',
          'revision': 1,
          'created_at': '2026-08-01T00:00:00Z',
          'updated_at': '2026-08-01T00:00:00Z',
        },
        {
          'companion_id': 'c_retired',
          'display_name': '退役的',
          'kind': 'standard',
          'lifecycle_state': 'archived',
          'revision': 1,
          'created_at': '2026-08-01T00:00:00Z',
          'updated_at': '2026-08-01T00:00:00Z',
        },
      ],
      'next_cursor': null,
    });

void main() {
  testWidgets('binding names the Companion, the device and the revision',
      (tester) async {
    final calls = <Map<String, Object?>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MountedDeviceDetailPage(
          device: _device(revision: 4),
          onRemove: (_, __) async => throw StateError('not this test'),
          loadCompanions: () async => _roster(),
          onBindCompanion: ({
            required String deviceId,
            required String requestId,
            required String? companionId,
            required int expectedRevision,
          }) async {
            calls.add({
              'device': deviceId,
              'companion': companionId,
              'revision': expectedRevision,
              'request': requestId,
            });
          },
        ),
      ),
    );

    expect(find.text('尚未关联'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bind-device-companion')));
    await tester.pumpAndSettle();

    // An archived Eidolon is not offered: it cannot answer through anything.
    expect(find.byKey(const Key('companion-choice-c_01')), findsOneWidget);
    expect(find.byKey(const Key('companion-choice-c_retired')), findsNothing);
    // Nothing to release yet, so releasing is not offered either.
    expect(find.byKey(const Key('companion-choice-none')), findsNothing);

    await tester.tap(find.byKey(const Key('companion-choice-c_01')));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single['companion'], 'c_01');
    expect(calls.single['revision'], 4);
    // The revision the screen was showing travels with the change, so two
    // phones changing the same device do not take turns unnoticed.
    expect(calls.single['request'], startsWith('device-companion-'));
  });

  testWidgets('a bound device can be released', (tester) async {
    final calls = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MountedDeviceDetailPage(
          device: _device(companionId: 'c_01', revision: 5),
          onRemove: (_, __) async => throw StateError('not this test'),
          loadCompanions: () async => _roster(),
          onBindCompanion: ({
            required String deviceId,
            required String requestId,
            required String? companionId,
            required int expectedRevision,
          }) async {
            calls.add(companionId);
          },
        ),
      ),
    );

    expect(find.text('c_01'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bind-device-companion')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion-choice-none')));
    await tester.pumpAndSettle();

    expect(calls, [null]);
  });

  testWidgets('a refusal is shown, not swallowed', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MountedDeviceDetailPage(
          device: _device(),
          onRemove: (_, __) async => throw StateError('not this test'),
          loadCompanions: () async => _roster(),
          onBindCompanion: ({
            required String deviceId,
            required String requestId,
            required String? companionId,
            required int expectedRevision,
          }) async {
            throw const LocalApiRefusal('主机不接受这台设备当前的状态。');
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('bind-device-companion')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion-choice-c_01')));
    await tester.pumpAndSettle();

    expect(find.textContaining('关联没有完成'), findsOneWidget);
    expect(find.textContaining('主机不接受'), findsOneWidget);
  });

  testWidgets('a Host with no usable Eidolon says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MountedDeviceDetailPage(
          device: _device(),
          onRemove: (_, __) async => throw StateError('not this test'),
          loadCompanions: () async => CompanionRosterView.fromJson({
            'contract_version': '1',
            'default_companion_id': null,
            'companions': <dynamic>[],
            'next_cursor': null,
          }),
          onBindCompanion: ({
            required String deviceId,
            required String requestId,
            required String? companionId,
            required int expectedRevision,
          }) async =>
              throw StateError('nothing to bind'),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('bind-device-companion')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('device-companion-picker-empty')),
      findsOneWidget,
    );
  });

  testWidgets('a Host that cannot be asked offers nothing to press',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MountedDeviceDetailPage(
          device: _device(),
          onRemove: (_, __) async => throw StateError('not this test'),
        ),
      ),
    );

    expect(find.byKey(const Key('device-companion-binding')), findsOneWidget);
    expect(find.byKey(const Key('bind-device-companion')), findsNothing);
  });
}

class LocalApiRefusal implements Exception {
  const LocalApiRefusal(this.message);
  final String message;
  @override
  String toString() => message;
}
