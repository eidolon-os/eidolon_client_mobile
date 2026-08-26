import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/device_management/mounted_devices_page.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A mounted device answers as somebody, or as nobody. Until this screen could
/// say which, every device this product added arrived correct and unusable:
/// mounted, claimed, and bound to no Companion, with no way forward.

MountedDevice _device({
  String? companionId,
  int revision = 1,
  String state = 'ready',
  String quietBecause = '',
}) =>
    MountedDevice.fromView(
      DeviceView.fromJson({
        'device_id': 'device-instance-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        'label': 'box3-device-manifest',
        'kind': 'box3-device-manifest',
        'state': state,
        'answers_as_companion_id': companionId,
        'answers_as_companion_name': companionId == null ? '' : '小忆',
        'quiet_because': quietBecause,
        'revision': revision,
        'mount_revision': 7,
        'updated_at': '2026-08-25T08:10:00Z',
        'online': 'unknown',
        'online_reason': '这台主机没有任何东西在观测设备是否开着',
        'claim_state': state == 'access_revoked' ? 'revoked' : 'active',
        'claim_generation': 2,
        'trust_epoch': 1,
        'owner_domain_generation': 3,
        'manifest_id': 'box3-device-manifest',
        'manifest_revision': 1,
      }),
    );

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

    // Nobody has decided about this device yet, which is not the same as its
    // having gone quiet — and the revision it will send is the Body's.
    expect(find.text('还没有指定'), findsOneWidget);
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

    // The name, not the identifier: the row says who answers.
    expect(find.text('小忆'), findsOneWidget);
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

  testWidgets('a speaker that went quiet says which way it went quiet',
      (tester) async {
    // The three ways of answering as nobody leave the same empty assignment
    // behind. Telling someone whose Eidolon was put away that they had "not
    // decided yet" is the one reading that makes a working Host look broken.
    Future<void> show(String word) => tester.pumpWidget(
          MaterialApp(
            home: MountedDeviceDetailPage(
              device: _device(state: 'awaiting_companion', quietBecause: word),
              onRemove: (_, __) async => throw StateError('not this test'),
            ),
          ),
        );

    await show('you_cleared_it');
    expect(find.text('你把它设成了不由谁应答'), findsOneWidget);

    await show('companion_put_away');
    expect(find.text('原本应答的 Eidolon 被收起来了'), findsOneWidget);

    await show('');
    expect(find.text('还没有指定'), findsOneWidget);
  });

  test('the control is held back only once the Host has said it cannot', () {
    // Two halves, and the second is the one that bites. `body.assign` is read
    // apart from `device.manage` because a Host could offer one and not the
    // other — but a Host that has not been asked yet must not read as one that
    // refused, or every control vanishes for the moment between connecting and
    // reading /context.
    ManagementContextView context({required bool assign}) =>
        ManagementContextView.fromJson({
          'owner': {
            'owner_id': 'owner_1',
            'display_name': '曼森',
            'revision': 1,
          },
          'default_companion_id': 'c_01',
          'capabilities': {'body.assign': assign, 'device.manage': true},
          'unavailable': assign ? <String, String>{} : {'body.assign': 'not_built'},
          'limits': <String, int?>{},
        });

    expect(hostOffersBodyAssignment(null), isTrue);
    expect(hostOffersBodyAssignment(context(assign: true)), isTrue);
    expect(hostOffersBodyAssignment(context(assign: false)), isFalse);
  });
}

class LocalApiRefusal implements Exception {
  const LocalApiRefusal(this.message);
  final String message;
  @override
  String toString() => message;
}
