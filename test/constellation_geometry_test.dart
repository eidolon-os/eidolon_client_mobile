import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:eidolon_client_mobile/src/features/constellation/cockpit_models.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

/// The layout is the part of this screen a screenshot hides: a moon tucked under
/// its planet or a body port off the canvas both look plausible in a still and
/// are unusable under a finger. So it is measured here.

CompanionUnit _unit({
  required String id,
  String name = '伙伴',
  int devices = 1,
  int onlineDevices = 1,
  String realm = 'realm-1',
  int? recall = 3,
  List<CockpitActivity> activities = const <CockpitActivity>[],
  bool primary = false,
}) {
  final bodies = <CockpitDevice>[
    for (var index = 0; index < devices; index += 1)
      CockpitDevice(
        deviceId: '$id-body-$index',
        name: '身体 $index',
        kind: 'esp32-s3',
        status: index < onlineDevices ? 'active' : 'offline',
        online: index < onlineDevices,
        companionId: id,
      ),
  ];
  return CompanionUnit(
    companion: CockpitCompanion(
      companionId: id,
      displayName: name,
      status: 'active',
      genomeId: 'genome-$id',
      realmId: realm,
      recallHits: recall,
    ),
    devices: bodies,
    isDefault: primary,
    activities: activities,
    turns: const <CockpitTurn>[],
    jobs: const <CockpitJob>[],
  );
}

CockpitActivity _activity({
  required String id,
  required String companionId,
  String kind = 'voice_turn',
  String status = 'running',
  String outcome = 'deferred',
  DateTime? updatedAt,
}) =>
    CockpitActivity(
      activityId: id,
      kind: kind,
      companionId: companionId,
      status: status,
      outcome: outcome,
      summary: '摘要',
      updatedAt: updatedAt,
    );

void main() {
  const metrics = ConstellationMetrics();

  group('constellation layout', () {
    test('每个伙伴都有身体、记忆、活动三颗卫星', () {
      final layout = buildConstellationLayout(
        units: [
          _unit(id: 'a'),
          _unit(id: 'b'),
          _unit(id: 'c'),
        ],
      );

      expect(layout.planets, hasLength(3));
      for (final planet in layout.planets) {
        expect(
          planet.moons.map((moon) => moon.kind),
          containsAll(MoonKind.values),
        );
      }
    });

    test('卫星不会压在行星上，相邻卫星之间留有可点击的间距', () {
      final layout = buildConstellationLayout(
        units: [_unit(id: 'a'), _unit(id: 'b'), _unit(id: 'c')],
      );

      for (final planet in layout.planets) {
        for (final moon in planet.moons) {
          final gap = (moon.center - planet.center).distance -
              metrics.planetRadius -
              metrics.moonRadius;
          expect(
            gap,
            greaterThan(0),
            reason: '${moon.key} 与行星重叠了 ${-gap}',
          );
        }
        // 相邻卫星之间也不能重叠：手指按不出两个不同的东西。
        for (var i = 0; i < planet.moons.length - 1; i += 1) {
          final apart =
              (planet.moons[i].center - planet.moons[i + 1].center).distance;
          expect(apart, greaterThan(metrics.moonRadius * 2));
        }
      }
    });

    test('卫星朝远离主人核心的一侧张开', () {
      final layout = buildConstellationLayout(units: [_unit(id: 'a')]);
      final planet = layout.planets.single;
      final planetDistance = (planet.center - layout.ownerCenter).distance;
      for (final moon in planet.moons) {
        expect(
          (moon.center - layout.ownerCenter).distance,
          greaterThan(planetDistance),
          reason: '${moon.key} 落在了朝向主人的一侧',
        );
      }
    });

    test('一到四位伙伴都留在画布里', () {
      for (var count = 1; count <= 4; count += 1) {
        final layout = buildConstellationLayout(
          units: [
            for (var index = 0; index < count; index += 1)
              _unit(id: 'c$index', devices: 2),
          ],
        );
        for (final planet in layout.planets) {
          for (final moon in planet.moons) {
            expect(
              moon.center.dx,
              inInclusiveRange(-40, layout.canvas.width + 40),
              reason: '$count 位伙伴时 ${moon.key} 横向溢出',
            );
            expect(
              moon.center.dy,
              inInclusiveRange(-40, layout.canvas.height + 40),
              reason: '$count 位伙伴时 ${moon.key} 纵向溢出',
            );
          }
        }
      }
    });

    test('第一位伙伴在正上方，纵向铺开而不是挤在水平线上', () {
      final layout = buildConstellationLayout(
        units: [_unit(id: 'a'), _unit(id: 'b')],
      );
      expect(
          layout.planets.first.center.dx, closeTo(layout.ownerCenter.dx, 0.01));
      expect(layout.planets.first.center.dy, lessThan(layout.ownerCenter.dy));
      expect(layout.planets.last.center.dy, greaterThan(layout.ownerCenter.dy));
    });

    test('身体端口挂在身体卫星上，最多五个', () {
      final layout = buildConstellationLayout(
        units: [_unit(id: 'a', devices: 7, onlineDevices: 2)],
      );
      final planet = layout.planets.single;
      final body = planet.moon(MoonKind.body)!;
      expect(planet.ports, hasLength(5));
      for (final port in planet.ports) {
        expect(port.bodyCenter, body.center);
        expect(
          (port.center - body.center).distance,
          closeTo(metrics.portOrbit, 0.01),
        );
      }
    });

    test('活动中的身体端口被标为在链路上', () {
      const active = CockpitActivity(
        activityId: 'act-1',
        kind: 'voice_turn',
        companionId: 'a',
        status: 'running',
        summary: '对话中',
        originDeviceId: 'a-body-0',
      );
      final layout = buildConstellationLayout(
        units: [
          _unit(id: 'a', devices: 2, activities: const [active])
        ],
      );
      final ports = layout.planets.single.ports;
      expect(ports.first.active, isTrue);
      expect(ports.last.active, isFalse);
    });

    test('活动珠最多三颗，进行中的排在前面', () {
      final now = DateTime.utc(2026, 8, 24, 12);
      final layout = buildConstellationLayout(
        now: now,
        units: [
          _unit(
            id: 'a',
            activities: [
              _activity(
                id: 'old',
                companionId: 'a',
                status: 'completed',
                updatedAt: now.subtract(const Duration(minutes: 30)),
              ),
              _activity(
                id: 'recent',
                companionId: 'a',
                status: 'completed',
                updatedAt: now.subtract(const Duration(minutes: 1)),
              ),
              _activity(
                id: 'live',
                companionId: 'a',
                updatedAt: now.subtract(const Duration(minutes: 10)),
              ),
              _activity(
                id: 'older',
                companionId: 'a',
                status: 'completed',
                updatedAt: now.subtract(const Duration(hours: 3)),
              ),
            ],
          ),
        ],
      );
      final beads = layout.planets.single.beads;
      expect(beads, hasLength(3));
      expect(beads.first.activity.activityId, 'live');
      expect(beads.first.live, isTrue);
      expect(beads[1].activity.activityId, 'recent');
    });
  });

  group('moon facts', () {
    test('没有身体说未绑定，而不是 0 台', () {
      final facts = moonFacts(_unit(id: 'a', devices: 0), MoonKind.body);
      expect(facts.value, '未绑定');
      expect(facts.tone, CockpitTone.off);
      expect(facts.empty, isTrue);
    });

    test('有身体但都不在线是 idle，不是故障', () {
      final facts = moonFacts(
          _unit(id: 'a', devices: 2, onlineDevices: 0), MoonKind.body);
      expect(facts.tone, CockpitTone.idle);
      expect(facts.empty, isFalse);
    });

    test('没有记忆空间说无空间', () {
      final facts = moonFacts(_unit(id: 'a', realm: ''), MoonKind.mem);
      expect(facts.value, '无空间');
      expect(facts.tone, CockpitTone.off);
    });

    test('活动里有失败的一条会把卫星标红', () {
      final facts = moonFacts(
        _unit(
          id: 'a',
          activities: [
            _activity(
              id: 'x',
              companionId: 'a',
              status: 'failed',
              outcome: 'failure',
            ),
          ],
        ),
        MoonKind.act,
      );
      expect(facts.tone, CockpitTone.bad);
    });
  });

  group('runtime badge', () {
    test('对话中带上延迟', () {
      final unit = CompanionUnit(
        companion: const CockpitCompanion(
          companionId: 'a',
          displayName: '砚舟',
          status: 'active',
        ),
        devices: const <CockpitDevice>[],
        activities: [
          _activity(id: 'act', companionId: 'a', kind: 'voice_turn'),
        ],
        turns: const [
          CockpitTurn(
            turnId: 'turn-1',
            companionId: 'a',
            status: 'running',
            latencyMs: 180,
          ),
        ],
        jobs: const <CockpitJob>[],
      );
      expect(runtimeBadge(unit).text, '对话中 · 180ms');
      expect(runtimeBadge(unit).tone, CockpitTone.live);
    });

    test('只有后台任务时说任务数', () {
      final unit = CompanionUnit(
        companion: const CockpitCompanion(
          companionId: 'a',
          displayName: '青梧',
          status: 'active',
        ),
        devices: const <CockpitDevice>[],
        activities: const <CockpitActivity>[],
        turns: const <CockpitTurn>[],
        jobs: const [
          CockpitJob(
            jobId: 'job-1',
            companionId: 'a',
            kind: 'memory',
            status: 'running',
            summary: '整理',
          ),
        ],
      );
      expect(runtimeBadge(unit).text, '1 个任务');
      expect(runtimeBadge(unit).tone, CockpitTone.warn);
    });

    test('什么都没有就是空闲，不假装在忙', () {
      expect(runtimeBadge(_unit(id: 'a')).text, '空闲');
      expect(runtimeBadge(_unit(id: 'a')).tone, CockpitTone.idle);
    });
  });

  test('椭圆比宽更高，画布也是竖的', () {
    // 手机是竖的：椭圆必须比宽更高，否则伙伴会挤在一条水平线上，
    // 上下留出两块空白。
    expect(metrics.orbitRadiusY, greaterThan(metrics.orbitRadiusX));
    expect(metrics.startDegrees, -90);
    expect(metrics.moonSpreadDegrees * math.pi / 180, greaterThan(0));

    final layout = buildConstellationLayout(
      units: [_unit(id: 'a'), _unit(id: 'b'), _unit(id: 'c')],
    );
    expect(layout.canvas.height, greaterThan(layout.canvas.width));
  });

  test('画布贴着内容走：伙伴少了地图也不留空band', () {
    for (var count = 1; count <= 4; count += 1) {
      final layout = buildConstellationLayout(
        units: [
          for (var index = 0; index < count; index += 1)
            _unit(id: 'c$index', devices: 1),
        ],
      );
      var box = Rect.fromCircle(
        center: layout.ownerCenter,
        radius: metrics.ownerRadius,
      );
      for (final planet in layout.planets) {
        box = box.expandToInclude(
          Rect.fromCircle(center: planet.center, radius: metrics.planetRadius),
        );
        for (final moon in planet.moons) {
          box = box.expandToInclude(
            Rect.fromCircle(center: moon.center, radius: metrics.moonRadius),
          );
        }
      }
      // 内容盒子和画布之间只允许留下 padding 那一圈（活动珠和端口可能更外，
      // 所以只做单边上界检查）。
      expect(box.left, lessThanOrEqualTo(metrics.padding + 70));
      expect(box.top, lessThanOrEqualTo(metrics.padding + 70));
      expect(
        layout.canvas.width - box.right,
        lessThanOrEqualTo(metrics.padding + 70),
        reason: '$count 位伙伴时右侧留了空 band',
      );
      expect(
        layout.canvas.height - box.bottom,
        lessThanOrEqualTo(metrics.padding + 70),
        reason: '$count 位伙伴时底部留了空 band',
      );
    }
  });
}
