import 'dart:async';

import 'package:eidolon_client_mobile/src/features/constellation/cockpit_feed.dart';
import 'package:eidolon_client_mobile/src/features/constellation/cockpit_mock_feed.dart';
import 'package:eidolon_client_mobile/src/features/constellation/cockpit_models.dart';
import 'package:eidolon_client_mobile/src/features/constellation/companion_inspector.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_cockpit_page.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_nodes.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_stage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The cockpit on a phone-sized surface, with motion switched off so a scene can
/// be pinned. Every assertion here is about something a reader would notice was
/// wrong: a planet that cannot be tapped, an asset that opens the wrong tab, a
/// dead service shown as healthy.

Future<void> _openCockpit(
  WidgetTester tester,
  CockpitFeed feed, {
  Size physicalSize = const Size(1170, 2532),
  double devicePixelRatio = 3,
}) async {
  tester.view.physicalSize = physicalSize;
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      // The clock never starts under reduced motion, so painters render one
      // static frame and the test is not racing an animation. It has to be
      // injected inside MaterialApp: WidgetsApp installs its own view-derived
      // MediaQuery and would drop an ancestor override.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: ConstellationCockpitPage(openFeed: () => feed),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// A tick to let a just-started transition claim its first frame, then a jump to
/// its end. One `pump(duration)` alone leaves an animation at zero: the ticker
/// takes that frame as its start.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Finder _planet(String companionId) => find.byWidgetPredicate(
      (widget) =>
          widget is CompanionPlanet && widget.planet.unit.id == companionId,
    );

Finder _moon(String companionId, MoonKind kind) => find.byWidgetPredicate(
      (widget) =>
          widget is AssetMoon &&
          widget.moon.unit.id == companionId &&
          widget.moon.kind == kind,
    );

void main() {
  _contractTests();
  _failureTests();

  testWidgets('主人核心、伙伴行星和三颗卫星都画了出来', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    expect(find.byKey(const Key('constellation-cockpit-page')), findsOneWidget);
    expect(find.byType(OwnerCore), findsOneWidget);
    expect(find.text('沈亦'), findsOneWidget);
    expect(find.text('3 位伙伴'), findsOneWidget);
    expect(find.byType(CompanionPlanet), findsNWidgets(3));
    expect(find.byType(AssetMoon), findsNWidgets(9));
    expect(find.text('★ 砚舟'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('点行星进入聚焦，检查器停在概览', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    expect(find.byType(CompanionInspectorCard), findsNothing);

    await tester.tap(_planet('companion-yanzhou'));
    await _settle(tester);

    expect(find.byType(CompanionInspectorCard), findsOneWidget);
    expect(find.text('COMPANION FOCUS'), findsOneWidget);
    final card = tester.widget<CompanionInspectorCard>(
      find.byType(CompanionInspectorCard),
    );
    expect(card.unit.id, 'companion-yanzhou');
    expect(card.tab, InspectorTab.overview);

    await _close(tester);
  });

  testWidgets('打开时整张地图都在舞台里，不压到顶栏和背板', (tester) async {
    // 这条是照着真机上的一次事故写的：镜头对准的是主人核心，而画布贴着内容算，
    // 竖向轨道让核心以上的地图比以下多得多 —— 于是平板上顶部的卫星画到了顶栏上。
    // 对准的必须是地图中心，不是核心。
    for (final surface in <Size>[
      const Size(1170, 2532), // 手机
      const Size(2136, 3200), // 平板
      const Size(1080, 1920), // 矮一点的手机
    ]) {
      final feed = MockCockpitFeed(autoplay: false);
      await _openCockpit(tester, feed, physicalSize: surface);

      final stage = tester.getRect(find.byType(ConstellationStage));
      for (final finder in <Finder>[
        find.byType(CompanionPlanet),
        find.byType(AssetMoon),
        find.byType(OwnerCore),
      ]) {
        for (final element in finder.evaluate()) {
          final box = tester.getRect(find.byWidget(element.widget));
          expect(
            stage.contains(box.topLeft) && stage.contains(box.bottomRight),
            isTrue,
            reason: '$surface 上 ${element.widget.runtimeType} 越出舞台：'
                '$box 不在 $stage 里',
          );
        }
      }

      await _close(tester);
      feed.dispose();
    }
  });

  testWidgets('聚焦时镜头飞向那颗行星，把它抬到检查器上方', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    final planet = _planet('companion-yanzhou');
    final before = tester.getRect(planet);

    await tester.tap(planet);
    await tester.pump();
    // 镜头动画是在 post-frame 回调里起步的，ticker 把它看到的第一帧当作零点，
    // 所以要多给一帧。
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 900));
    final after = tester.getRect(planet);

    // 放大到看得清，并且被抬到检查器卡片上方。
    expect(after.width, greaterThan(before.width * 1.2));
    expect(after.center.dy, lessThan(400));

    await _close(tester);
  });

  testWidgets('点记忆卫星直接落在记忆页，不用先进伙伴再翻页', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    await tester.tap(_moon('companion-yanzhou', MoonKind.mem));
    await _settle(tester);

    final card = tester.widget<CompanionInspectorCard>(
      find.byType(CompanionInspectorCard),
    );
    expect(card.tab, InspectorTab.memory);
    expect(find.text('伙伴记忆域已连接'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('没有记忆空间的伙伴说未开通，不是空白', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    await tester.tap(_moon('companion-linyuan', MoonKind.mem));
    await _settle(tester);

    expect(find.text('尚未开通记忆空间'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('点空白处取消聚焦', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    await tester.tap(_planet('companion-qingwu'));
    await _settle(tester);
    expect(find.byType(CompanionInspectorCard), findsOneWidget);

    // 星图左上角的空白：既不在任何节点上，也不在背板上。
    await tester.tapAt(const Offset(14, 170));
    await _settle(tester);

    final card = tester.widgetList<CompanionInspectorCard>(
      find.byType(CompanionInspectorCard),
    );
    expect(card, isEmpty);

    await _close(tester);
  });

  testWidgets('背板收起时也说清底座有几个在跑', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    expect(find.text('LIVE KERNEL'), findsOneWidget);
    // 7 个底座里有一个没有回应，收起的背板必须让这件事看得见。
    expect(find.text('CORE 6/7'), findsOneWidget);
    expect(find.text('设备中枢'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('没有回应的外挂扩展在底座页说离线，并被单独点名', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    await tester.tap(find.text('展开 ⌃'));
    await _settle(tester);
    await tester.tap(find.textContaining('底座 ').last);
    await _settle(tester);

    expect(find.text('Mementos'), findsOneWidget);
    expect(find.text('离线'), findsWidgets);
    expect(find.text('外挂扩展（非核心链路）'), findsOneWidget);
    // 「一个服务离线」和「一条 lane 读不到」是两件事。这一屏所有 lane 都读到了，
    // 所以不该出现「读不到」的点名 —— 早先的实现把两者混成一个字段。
    expect(find.textContaining('它们的状态是未知'), findsNothing);

    await _close(tester);
  });

  testWidgets('某条 lane 读不到时，表盘显示 — 而不是 0，并被点名', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    // 推进到脚本里记忆服务不回应的那一拍（对脚本改动稳健）。
    var guard = 0;
    while ((feed.snapshot?.memoryLane.readable ?? true) && guard < 40) {
      feed.step();
      guard += 1;
    }
    await _settle(tester);
    expect(feed.snapshot!.memoryLane.readable, isFalse);
    expect(feed.snapshot!.unreadableLanes, contains('记忆'));

    // 记忆空间那一格必须是「—」：0 是一次测量，读不到不是。
    // 表盘条是横向滚动的，窄屏上第四格没被构建，所以先滚过去。
    await tester.drag(find.byType(ListView).first, const Offset(-260, 0));
    await _settle(tester);
    expect(find.text('记忆空间'), findsOneWidget);
    expect(find.text('—'), findsWidgets);

    await tester.tap(find.text('展开 ⌃'));
    await _settle(tester);
    await tester.tap(find.textContaining('底座 ').last);
    await _settle(tester);
    expect(find.textContaining('它们的状态是未知'), findsOneWidget);
    expect(find.textContaining('记忆'), findsWidgets);

    await _close(tester);
  });

  testWidgets('待认领设备单独成一块，不混进任何伙伴', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    expect(find.text('待认领设备'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('脚本推进后出现进行中的链路，行星显示对话中', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    // 第一拍：客厅音箱接入，砚舟开始一轮对话。
    feed.step();
    await _settle(tester);

    expect(feed.snapshot?.pipelineActive, isTrue);
    expect(find.text('对话中'), findsOneWidget);
    expect(find.textContaining('客厅音箱 加入语音房间'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('演示数据被标成 MOCK，不假装是主机说的', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    expect(find.text('MOCK'), findsWidgets);

    feed.step();
    await _settle(tester);
    expect(find.text('MOCK'), findsWidgets);

    await _close(tester);
  });

  testWidgets('点主人核心打开主权域详情，并说明这里不谈伙伴在线', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    await tester.tap(find.byType(OwnerCore));
    await _settle(tester);

    expect(find.text('OWNER · 主人'), findsWidgets);
    expect(find.textContaining('没有为伙伴发布过任何心跳'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('展开背板可以看到活动、事件与底座三页', (tester) async {
    final feed = MockCockpitFeed(autoplay: false);
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    feed.step();
    await _settle(tester);

    await tester.tap(find.text('展开 ⌃'));
    await _settle(tester);

    expect(find.textContaining('活动 '), findsOneWidget);
    expect(find.textContaining('事件 '), findsOneWidget);
    expect(find.textContaining('底座 '), findsOneWidget);

    await tester.tap(find.textContaining('事件 ').last);
    await _settle(tester);
    expect(find.textContaining('客厅音箱 加入语音房间'), findsWidgets);

    await _close(tester);
  });
}

/// A feed whose stream fails after handing over one good snapshot — the shape a
/// pinned HTTPS adapter will actually fail in (a read succeeds, then the Host
/// moves, the session expires, or the socket drops).
class _FailingFeed implements CockpitFeed {
  _FailingFeed() : _backing = MockCockpitFeed(autoplay: false);

  final MockCockpitFeed _backing;
  final _updates = StreamController<CockpitSnapshot>.broadcast();
  final _pulses = StreamController<CockpitPulse>.broadcast();
  final _observations = StreamController<CockpitObservation>.broadcast();
  StreamSubscription<CockpitSnapshot>? _backingSub;
  var refreshes = 0;
  var paused = false;

  @override
  CockpitSnapshot? get snapshot => _backing.snapshot;

  @override
  CockpitObservation get observation => _backing.observation;

  @override
  Stream<CockpitSnapshot> get updates => _updates.stream;

  @override
  Stream<CockpitPulse> get pulses => _pulses.stream;

  @override
  Stream<CockpitObservation> get observations => _observations.stream;

  @override
  void start() {
    // Subscribe before starting the staged world, then let it read: whatever it
    // publishes travels this feed's own channel so `fail` can break the same one.
    _backingSub ??= _backing.updates.listen(_updates.add);
    _backing.start();
  }

  @override
  void pause() => paused = true;

  @override
  void resume() => paused = false;

  void fail(Object error) => _updates.addError(error);

  @override
  Future<void> refresh() async {
    refreshes += 1;
    throw StateError('主机仍然没有回应');
  }

  @override
  void dispose() {
    _backingSub?.cancel();
    _updates.close();
    _pulses.close();
    _observations.close();
    _backing.dispose();
  }
}

void _failureTests() {
  testWidgets('读不到投影时说出来，并且不让屏幕假装一切正常', (tester) async {
    final feed = _FailingFeed();
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    // 先确认正常态：没有失败条，链路是 ONLINE。
    expect(find.byKey(const Key('cockpit-read-failure')), findsNothing);
    expect(find.text('ONLINE'), findsOneWidget);

    feed.fail(StateError('pinned host 无法验证'));
    await _settle(tester);

    // 失败必须有自己的位置，而不是把星图渲染成「什么都没发生」。
    expect(find.byKey(const Key('cockpit-read-failure')), findsOneWidget);
    expect(find.text('读不到这台主机的运行投影'), findsOneWidget);
    // 屏幕上是哪一次读取的样子，必须说清楚。
    expect(find.textContaining('那一次读取的样子'), findsOneWidget);
    // 顶栏不能继续宣称在线。
    expect(find.text('ONLINE'), findsNothing);
    expect(find.text('UNSTABLE'), findsOneWidget);
    // 星图还在（最后一次事实），不是一片空白。
    expect(find.byType(OwnerCore), findsOneWidget);

    await _close(tester);
  });

  testWidgets('重试失败了还是失败，不会悄悄变成正常', (tester) async {
    final feed = _FailingFeed();
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    feed.fail(StateError('socket 断了'));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('retry-cockpit-read')));
    await _settle(tester);

    expect(feed.refreshes, 1);
    expect(find.byKey(const Key('cockpit-read-failure')), findsOneWidget);
    expect(find.textContaining('主机仍然没有回应'), findsOneWidget);

    await _close(tester);
  });
}

/// A feed that has never read anything — the state every real adapter starts in
/// and the one a mock hides by having facts on construction.
class _UnreadFeed implements CockpitFeed {
  final _updates = StreamController<CockpitSnapshot>.broadcast();
  final _pulses = StreamController<CockpitPulse>.broadcast();
  final _observations = StreamController<CockpitObservation>.broadcast();
  var _observation =
      const CockpitObservation(state: ObservationState.connecting);
  var refreshes = 0;
  var starts = 0;

  @override
  CockpitSnapshot? get snapshot => null;

  @override
  CockpitObservation get observation => _observation;

  @override
  Stream<CockpitSnapshot> get updates => _updates.stream;

  @override
  Stream<CockpitPulse> get pulses => _pulses.stream;

  @override
  Stream<CockpitObservation> get observations => _observations.stream;

  void failFirstRead(String detail) {
    _observation = CockpitObservation(
      state: ObservationState.lost,
      detail: detail,
    );
    _observations.add(_observation);
  }

  @override
  void start() => starts += 1;

  @override
  Future<void> refresh() async => refreshes += 1;

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  void dispose() {
    _updates.close();
    _pulses.close();
    _observations.close();
  }
}

void _contractTests() {
  testWidgets('第一次读取落地之前不画星图，也不假装是空的域', (tester) async {
    final feed = MockCockpitFeed(
      autoplay: false,
      // 比打开这一屏本身的 pump 更久，否则断言时读取已经落地了。
      firstReadDelay: const Duration(seconds: 3),
    );
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    // 还没有事实：星图一个节点都不画。
    expect(find.byKey(const Key('constellation-first-read')), findsOneWidget);
    expect(find.byType(OwnerCore), findsNothing);
    expect(find.text('正在读取这台主机的运行投影'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await _settle(tester);

    // 读到了才有星图。
    expect(find.byKey(const Key('constellation-first-read')), findsNothing);
    expect(find.byType(OwnerCore), findsOneWidget);

    await _close(tester);
  });

  testWidgets('第一次读取就失败：说出来并给重试，而不是空转', (tester) async {
    final feed = _UnreadFeed();
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);

    feed.failFirstRead('pinned host 无法验证');
    await _settle(tester);

    expect(find.text('没能读到这台主机的运行投影'), findsOneWidget);
    expect(find.textContaining('pinned host 无法验证'), findsOneWidget);
    // 关键区别要说出口：这一屏从没成功读过，所以它什么都不画。
    expect(find.textContaining('不该长成同一张'), findsOneWidget);
    expect(find.byType(OwnerCore), findsNothing);

    await tester.tap(find.byKey(const Key('retry-first-read')));
    await _settle(tester);
    expect(feed.refreshes, 1);

    await _close(tester);
  });

  testWidgets('切到后台暂停消费，回到前台继续', (tester) async {
    final feed = _FailingFeed();
    addTearDown(feed.dispose);
    await _openCockpit(tester, feed);
    expect(feed.paused, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _settle(tester);
    expect(feed.paused, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);
    expect(feed.paused, isFalse);

    await _close(tester);
  });

  testWidgets('mock 的暂停真的把脚本停住了', (tester) async {
    final feed = MockCockpitFeed();
    addTearDown(feed.dispose);
    expect(feed.running, isTrue);
    feed.pause();
    expect(feed.running, isFalse);
    feed.resume();
    expect(feed.running, isTrue);
    // 停回去，别把定时器留给测试收尾。
    feed.pause();
  });
}
