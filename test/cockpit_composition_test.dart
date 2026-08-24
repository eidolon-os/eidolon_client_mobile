import 'package:eidolon_client_mobile/src/features/constellation/cockpit_composition.dart';
import 'package:eidolon_client_mobile/src/features/constellation/cockpit_models.dart';
import 'package:eidolon_client_mobile/src/features/constellation/cockpit_wire.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_geometry.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:flutter_test/flutter_test.dart';

/// Three authorities, one screen.
///
/// The star map is drawn from `/context` (who the Owner is), the roster (which
/// Companions exist) and Mission Control (what they are doing). The case that
/// has to be right is the one that is true today: the first two answer and the
/// third does not exist yet.

ManagementContextView _context({String? defaultId = 'c-yanzhou'}) =>
    ManagementContextView(
      owner: OwnerContextView(
        ownerId: 'owner-shenyi',
        displayName: '沈亦',
        revision: 3,
      ),
      defaultCompanionId: defaultId,
      capabilities: const <String, bool>{},
      limits: const <String, int?>{},
    );

CompanionRosterView _roster({
  String? defaultId = 'c-yanzhou',
  List<CompanionSummaryView>? rows,
}) =>
    CompanionRosterView(
      companions: rows ??
          <CompanionSummaryView>[
            CompanionSummaryView(
              companionId: 'c-yanzhou',
              displayName: '砚舟',
              kind: 'companion',
              lifecycleState: 'active',
              revision: 4,
              createdAt: '2026-08-01T00:00:00Z',
              updatedAt: '2026-08-24T00:00:00Z',
            ),
            CompanionSummaryView(
              companionId: 'c-linyuan',
              displayName: '临渊',
              kind: 'companion',
              lifecycleState: 'archived',
              revision: 2,
              createdAt: '2026-08-02T00:00:00Z',
              updatedAt: '2026-08-20T00:00:00Z',
            ),
          ],
      defaultCompanionId: defaultId,
      nextCursor: null,
    );

CockpitComposer _composer({
  RuntimeRead? runtime,
  ManagementContextView? context,
  CompanionRosterView? roster,
}) =>
    CockpitComposer(
      readContext: () async => context ?? _context(),
      readRoster: () async => roster ?? _roster(),
      readRuntime: runtime,
    );

void main() {
  test('roster 读到、Mission Control 还不存在:行星画出来，卫星说读不到', () async {
    // 这是今天的真实状态。星图必须能画出主人真实的伙伴，
    // 同时**不假装**知道它们在干什么。
    final snapshot = await _composer().read();

    expect(snapshot.owner.displayName, '沈亦');
    expect(snapshot.companions, hasLength(2));
    expect(snapshot.defaultCompanionId, 'c-yanzhou');

    // 每一条运行 lane 都是「读不到」，而且带得出原因。
    for (final lane in <CockpitLane<Object?>>[
      snapshot.devicesLane,
      snapshot.activitiesLane,
      snapshot.turnsLane,
      snapshot.jobsLane,
      snapshot.memoryLane,
      snapshot.servicesLane,
      snapshot.eventsLane,
    ]) {
      expect(lane.readable, isFalse);
      expect(lane.detail, isNotEmpty);
    }

    // 而屏幕上的卫星必须说读不到，不能说「未绑定」或「空闲」——
    // 那会把「没问到」画成「没有」。
    final unit = CompanionUnit(
      companion: snapshot.companions.first,
      devices: const <CockpitDevice>[],
      activities: const <CockpitActivity>[],
      turns: const <CockpitTurn>[],
      jobs: const <CockpitJob>[],
      bodiesReadable: snapshot.devicesLane.readable,
      activitiesReadable: snapshot.activitiesLane.readable,
      recallReadable: snapshot.turnsLane.readable,
    );
    expect(moonFacts(unit, MoonKind.body).value, '读不到');
    expect(moonFacts(unit, MoonKind.act).value, '读不到');
    expect(runtimeBadge(unit).text, '活动读不到');
  });

  test('身份读不到就不画:主人和伙伴缺一不可', () async {
    // 运行事实可以缺，身份不能缺 —— 没有主人没有伙伴的星图无物可画，
    // 这时候抛出去、让页面显示首次读取失败，比画一张空图诚实。
    final composer = CockpitComposer(
      readContext: () async => throw StateError('pinned host 无法验证'),
      readRoster: () async => _roster(),
    );
    await expectLater(composer.read(), throwsA(isA<StateError>()));
  });

  test('Mission Control 读失败只是观测降级，不是域停了', () async {
    final snapshot = await _composer(
      runtime: () async => throw StateError('socket 断了'),
    ).read();

    // 伙伴照常在。
    expect(snapshot.companions, hasLength(2));
    expect(snapshot.activitiesLane.readable, isFalse);
    expect(snapshot.activitiesLane.detail, contains('socket 断了'));
  });

  test('Mission Control 读到了就用它的 lane，并把召回补到伙伴上', () async {
    final snapshot = await _composer(
      runtime: () async => CockpitRuntime(
        observedAt: DateTime.utc(2026, 8, 24, 5),
        cursor: 42,
        devices: const CockpitLane<List<CockpitDevice>>.ok(<CockpitDevice>[]),
        activities:
            const CockpitLane<List<CockpitActivity>>.ok(<CockpitActivity>[]),
        turns: const CockpitLane<List<CockpitTurn>>.ok(<CockpitTurn>[
          CockpitTurn(
            turnId: 't1',
            companionId: 'c-yanzhou',
            status: 'completed',
            memoryHits: 7,
          ),
        ]),
        jobs: const CockpitLane<List<CockpitJob>>.ok(<CockpitJob>[]),
        memory: const CockpitLane<CockpitMemory?>.ok(CockpitMemory()),
        services:
            const CockpitLane<List<CockpitService>>.ok(<CockpitService>[]),
        events: const CockpitLane<List<CockpitEvent>>.ok(<CockpitEvent>[]),
      ),
    ).read();

    expect(snapshot.cursor, 42);
    expect(snapshot.unreadableLanes, isEmpty);
    // 召回从伙伴自己那次 turn 上来，不是逐伙伴问记忆服务。
    final master = snapshot.companions
        .firstWhere((item) => item.companionId == 'c-yanzhou');
    expect(master.recallHits, 7);
    // 没有 turn 的伙伴就是没有，不是 0。
    final archived = snapshot.companions
        .firstWhere((item) => item.companionId == 'c-linyuan');
    expect(archived.recallHits, isNull);
  });

  test('默认指针优先用随 roster 一起来的那个', () async {
    // 两个权威都说得出默认是谁。取和这份列表同一次读取的那个，
    // 否则一个过期的指针会把标记打在错误的行星上。
    final snapshot = await _composer(
      context: _context(defaultId: 'c-linyuan'),
      roster: _roster(defaultId: 'c-yanzhou'),
    ).read();
    expect(snapshot.defaultCompanionId, 'c-yanzhou');

    // roster 没说时才回落到 /context。
    final fallback = await _composer(
      context: _context(defaultId: 'c-linyuan'),
      roster: _roster(defaultId: null),
    ).read();
    expect(fallback.defaultCompanionId, 'c-linyuan');
  });

  test('正在删除的伙伴不画在图上', () async {
    // 归档和退役中的留着——主人自己放那儿的，徽标会说明；
    // 正在删除的画上去，等于主人要它走之后它还在。
    expect(
      drawableOnMap(
        const CockpitCompanion(
          companionId: 'c',
          displayName: 'x',
          status: 'archived',
        ),
      ),
      isTrue,
    );
    expect(
      drawableOnMap(
        const CockpitCompanion(
          companionId: 'c',
          displayName: 'x',
          status: 'deleting',
        ),
      ),
      isFalse,
    );
  });
}
