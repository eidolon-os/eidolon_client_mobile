import 'dart:async';

import 'package:eidolon_client_mobile/src/features/constellation/cockpit_feed.dart';
import 'package:eidolon_client_mobile/src/features/constellation/cockpit_mock_feed.dart';
import 'package:eidolon_client_mobile/src/features/constellation/cockpit_models.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_cockpit_page.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_nodes.dart';
import 'package:eidolon_client_mobile/src/features/constellation/polled_cockpit_feed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Who drives the observation, and when.
///
/// This file exists because of a defect nothing else here could have caught.
/// The star map read a real Host and showed "正在读取" forever: the page only
/// ever subscribed, `PolledCockpitFeed` only ever read when asked, and
/// `CockpitFeed` had no way to ask — while `MockCockpitFeed` published from its
/// own constructor, so every widget test above was driven by the feed rather
/// than by the screen. The seam between the two was never crossed by a test,
/// and nobody disposed the feed either, so a popped star map kept polling.
///
/// So the assertions here are about the seam itself and nothing else: the page
/// starts what it opened, in the right order, and closes it on the way out.
/// They are written against a recording fake, not against either real feed, so
/// they keep holding when the transport changes.

CockpitSnapshot _snapshot() => CockpitSnapshot(
      provenance: CockpitProvenance.host,
      generatedAt: DateTime.utc(2026, 8, 26, 4, 12),
      ownerLane: const CockpitLane<CockpitOwner?>.ok(
        CockpitOwner(ownerId: 'owner-1', displayName: '沈亦'),
      ),
      companionsLane: const CockpitLane<List<CockpitCompanion>>.ok(
        <CockpitCompanion>[],
      ),
      devicesLane: const CockpitLane<List<CockpitDevice>>.ok(<CockpitDevice>[]),
      servicesLane: const CockpitLane<List<CockpitService>>.ok(
        <CockpitService>[],
      ),
      memoryLane: const CockpitLane<CockpitMemory?>.ok(CockpitMemory()),
    );

/// Records the four transitions and nothing else. [publishOnStart] is how a feed
/// whose first read is already in hand behaves — synchronously, on the stream,
/// which is exactly the case a listener registered too late would miss.
class _RecordingFeed implements CockpitFeed {
  _RecordingFeed({this.publishOnStart = false});

  final bool publishOnStart;
  final _updates = StreamController<CockpitSnapshot>.broadcast();
  final _pulses = StreamController<CockpitPulse>.broadcast();
  final _observations = StreamController<CockpitObservation>.broadcast();

  var starts = 0;
  var pauses = 0;
  var resumes = 0;
  var disposals = 0;
  var refreshes = 0;

  CockpitSnapshot? _snap;
  var _observation =
      const CockpitObservation(state: ObservationState.connecting);

  @override
  CockpitSnapshot? get snapshot => _snap;

  @override
  CockpitObservation get observation => _observation;

  @override
  Stream<CockpitSnapshot> get updates => _updates.stream;

  @override
  Stream<CockpitPulse> get pulses => _pulses.stream;

  @override
  Stream<CockpitObservation> get observations => _observations.stream;

  @override
  void start() {
    starts += 1;
    if (publishOnStart) publish();
  }

  void publish() {
    _snap = _snapshot();
    _observation = CockpitObservation(
      state: ObservationState.live,
      lastReadAt: _snap!.generatedAt,
    );
    _updates.add(_snap!);
    _observations.add(_observation);
  }

  @override
  Future<void> refresh() async => refreshes += 1;

  @override
  void pause() => pauses += 1;

  @override
  void resume() => resumes += 1;

  @override
  void dispose() {
    disposals += 1;
    _updates.close();
    _pulses.close();
    _observations.close();
  }
}

Future<void> _open(WidgetTester tester, CockpitFeed Function() openFeed) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: ConstellationCockpitPage(openFeed: openFeed),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('打开这一屏就会让 feed 开始观测，而且只让它开始一次', (tester) async {
    final feed = _RecordingFeed();
    await _open(tester, () => feed);

    expect(feed.starts, 1);
    // 开始观测不是「读一次」：轮询的排期归实现，页面不替它安排。
    expect(feed.refreshes, 0);

    // 重建不是重新打开：State 还是那一个，feed 也还是那一个。
    await tester.pump(const Duration(seconds: 2));
    expect(feed.starts, 1);
  });

  testWidgets('feed 在 start 里同步给出的第一次读取不会丢', (tester) async {
    // 订阅必须早于 start。broadcast 流不为迟到的听众留事件，顺序反了这一屏就永远停在首读屏。
    final feed = _RecordingFeed(publishOnStart: true);
    await _open(tester, () => feed);

    expect(find.byKey(const Key('constellation-first-read')), findsNothing);
    expect(find.byType(OwnerCore), findsOneWidget);
  });

  testWidgets('离开这一屏就把 feed 关掉：不留一个没人看的轮询', (tester) async {
    final feed = _RecordingFeed(publishOnStart: true);
    await _open(tester, () => feed);
    expect(feed.disposals, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(feed.disposals, 1);
  });

  testWidgets('切到后台就停，回到前台就继续', (tester) async {
    final feed = _RecordingFeed(publishOnStart: true);
    await _open(tester, () => feed);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(feed.pauses, 1);
    expect(feed.resumes, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(feed.resumes, 1);
  });

  group('构造一个 feed 不产生任何观测', () {
    // 这条是对实现的约束，不是对页面的：自驱的实现会把「谁来启动」这个问题藏起来，
    // 而藏起来的那一次就是线上那次。新增实现请一并加到这张表里。
    final builders = <String, CockpitFeed Function()>{
      'MockCockpitFeed': () => MockCockpitFeed(autoplay: false),
      'PolledCockpitFeed': () =>
          PolledCockpitFeed(read: () async => _snapshot()),
    };

    for (final entry in builders.entries) {
      test('${entry.key}：没 start 就没有事实', () async {
        final feed = entry.value();
        addTearDown(feed.dispose);
        final seen = <CockpitSnapshot>[];
        feed.updates.listen(seen.add);

        // 给足够的时间让一个自驱的实现暴露自己。
        await Future<void>.delayed(Duration.zero);

        expect(feed.snapshot, isNull, reason: '构造函数不该已经读到东西');
        expect(seen, isEmpty, reason: '构造函数不该已经发布过');
        expect(feed.observation.state, ObservationState.connecting);
      });
    }
  });
}
