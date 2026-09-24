import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/shared_conversation_preparation_page.dart';
import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/theme/eidolon_theme.dart';

MountedDevice device(String id,
        {String state = 'ready', String? companion = 'mac'}) =>
    MountedDevice.fromView(DeviceView.fromJson({
      'device_id': id,
      'label': id,
      'kind': 'software',
      'state': state,
      'answers_as_companion_id': companion,
      'answers_as_companion_name': companion ?? '',
      'quiet_because': '',
      'revision': 1,
      'mount_revision': 1,
      'updated_at': '2026-09-01T00:00:00Z',
      'online': 'unknown',
      'online_reason': '',
      'claim_state': 'active',
      'claim_generation': 1,
      'trust_epoch': 1,
      'owner_domain_generation': 1,
      'manifest_id': id,
      'manifest_revision': 1,
      'outputs': {
        'capabilities': {'speech': true, 'dialogue_text': true},
        'revision': 0
      }
    }));

SharedConversationSnapshot scene({List<MountedDevice>? devices}) => (
      devices:
          devices ?? [device('Mobile'), device('BOX-3'), device('StackChan')],
      localDeviceId: 'Mobile',
      coverage: '',
    );

Widget app(Future<SharedConversationSnapshot> Function() load,
        {double scale = 1}) =>
    MaterialApp(
        theme: EidolonTheme.dark(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: SharedConversationPreparationPage(load: load));

void main() {
  testWidgets('preparation is explicit and never claims devices have joined',
      (tester) async {
    await tester.pumpWidget(app(() async => scene()));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 台设备'), findsOneWidget);
    expect(find.text('已加入'), findsNothing);
    await tester.tap(find.byKey(const Key('select-BOX-3')));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 台设备'), findsOneWidget);
    expect(find.textContaining('绑定伙伴：mac'), findsWidgets);
    expect(find.byKey(const Key('partner-BOX-3')), findsNothing);
    expect(find.text('开始一起聊'), findsNothing);
    expect(find.textContaining('尚未开放'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'refresh removes revoked selections and does not select new devices',
      (tester) async {
    var data = scene();
    await tester.pumpWidget(app(() async => data));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('select-BOX-3')));
    data = scene(devices: [
      device('Mobile'),
      device('BOX-3', state: 'access_revoked'),
      device('New')
    ]);
    await tester.tap(find.byTooltip('刷新设备与伙伴'));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 台设备'), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('select-BOX-3')))
            .onChanged,
        isNull);
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('select-New')))
            .value,
        false);
  });

  testWidgets(
      'binding is read from device details and unbinding removes participation',
      (tester) async {
    var data = scene(devices: [device('BOX-3')]);
    await tester.pumpWidget(app(() async => data));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('select-BOX-3')));
    data = scene(devices: [device('BOX-3', companion: '小方')]);
    await tester.tap(find.byTooltip('刷新设备与伙伴'));
    await tester.pumpAndSettle();
    expect(find.textContaining('绑定伙伴：小方'), findsOneWidget);
    expect(find.textContaining('绑定伙伴：mac'), findsNothing);
    data = scene(devices: [device('BOX-3', companion: null)]);
    await tester.tap(find.byTooltip('刷新设备与伙伴'));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 台设备'), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('select-BOX-3')))
            .onChanged,
        isNull);
  });

  testWidgets(
      'failed refresh does not present old inventory as a successful check',
      (tester) async {
    var fail = false;
    await tester.pumpWidget(app(() async {
      if (fail) throw StateError('offline');
      return scene();
    }));
    await tester.pumpAndSettle();
    fail = true;
    await tester.tap(find.byTooltip('刷新设备与伙伴'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('select-BOX-3')), findsNothing);
    expect(find.text('暂时无法读取设备与伙伴'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('select-BOX-3')), findsOneWidget);
  });

  testWidgets(
      'a non-mobile member can initiate and removing it clears only that input choice',
      (tester) async {
    final data = scene(devices: [device('BOX-3')]);
    await tester.pumpWidget(app(() async =>
        (devices: data.devices, localDeviceId: null, coverage: '')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('select-BOX-3')));
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('input-BOX-3'));
    await tester.ensureVisible(input);
    await tester.tap(input);
    await tester.pumpAndSettle();
    expect(find.text('当前输入入口'), findsOneWidget);
    expect(find.byKey(const Key('select-Mobile')), findsNothing);
    final selection = find.byKey(const Key('select-BOX-3'));
    await tester.ensureVisible(selection);
    await tester.tap(selection);
    await tester.pumpAndSettle();
    expect(find.text('当前输入入口'), findsNothing);
    expect(find.textContaining('手机收音'), findsNothing);
  });

  testWidgets(
      'inventory scope remains readable on demand without dominating preparation',
      (tester) async {
    final data = scene();
    const coverage = '仅包含已登记设备，待确认设备在另一份清单中；这里不表示在线状态。';
    await tester.pumpWidget(app(() async => (
          devices: data.devices,
          localDeviceId: data.localDeviceId,
          coverage: coverage
        )));
    await tester.pumpAndSettle();
    expect(find.text(coverage), findsNothing);
    await tester.tap(find.text('设备清单说明'));
    await tester.pumpAndSettle();
    expect(find.text(coverage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failure is retryable and late results after exit are ignored',
      (tester) async {
    var fail = true;
    final pending = Completer<SharedConversationSnapshot>();
    await tester.pumpWidget(app(() async {
      if (fail) throw StateError('private transport detail');
      return pending.future;
    }));
    await tester.pumpAndSettle();
    expect(find.text('private transport detail'), findsNothing);
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete(scene());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('small phone and enlarged text stay scrollable without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(() async => scene(), scale: 1.6));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(find.textContaining('选择仅保留在此页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
