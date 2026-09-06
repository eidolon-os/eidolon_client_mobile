import 'dart:convert';
import 'dart:io';

import 'package:eidolon_client_mobile/src/features/constellation/cockpit_models.dart';
import 'package:eidolon_client_mobile/src/features/constellation/cockpit_wire.dart';
import 'package:eidolon_client_mobile/src/features/constellation/constellation_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Parses the contract's own golden payloads.
///
/// The goldens live in the SDK — `eidolon_sdk/contracts/mission_control/v1/golden/` —
/// because that is where the contract lives, and both sides read the same files:
/// Python validates them against the schemas, this parses them. A copy in this
/// repository would be a second source of truth, which is the thing the shared
/// contract exists to avoid.
///
/// Skips when the sibling checkout is not present, the same way the SDK's own
/// cross-repository mirror tests do.
/// Returns the contract payload with one device row patched.
///
/// Everything except the field under test stays the contract's own. The row
/// must be there: a golden that changes shape has to turn this red rather than
/// quietly stop testing anything.
Map<String, Object?> _patchDevice(
  Map<String, Object?> json,
  String deviceId,
  void Function(Map<String, Object?> device) patch,
) {
  final copy = jsonDecode(jsonEncode(json)) as Map<String, Object?>;
  final lane = copy['devices']! as Map<String, Object?>;
  final items = (lane['items']! as List<Object?>).cast<Map<String, Object?>>();
  patch(items.singleWhere((item) => item['device_id'] == deviceId));
  return copy;
}

Map<String, Object?>? _golden(String name) {
  // Walk up looking for the SDK beside us. Not just `..`: this repository is
  // also worked on from a git worktree, which sits one level deeper, and a test
  // that silently skips because of that is a test that stops guarding anything.
  var directory = Directory.current;
  for (var depth = 0; depth < 4; depth += 1) {
    final file = File(
      '${directory.path}/eidolon_sdk/contracts/mission_control/v1/golden/$name',
    );
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return null;
}

void main() {
  group('契约黄金载荷', () {
    test('健康载荷：每条运行 lane 都读到了，而且不带身份', () {
      final json = _golden('snapshot-healthy.json');
      if (json == null) {
        markTestSkipped('eidolon_sdk checkout 不在旁边');
        return;
      }
      final runtime = parseMissionControlRuntime(json);

      expect(runtime.cursor, 10493);
      for (final lane in <CockpitLane<Object?>>[
        runtime.devices,
        runtime.activities,
        runtime.turns,
        runtime.jobs,
        runtime.memory,
        runtime.services,
        runtime.events,
      ]) {
        expect(lane.readable, isTrue);
      }
      // 身份不在这份载荷里：谁存在由 roster 说，主人由 /context 说。
      expect(json.containsKey('owner'), isFalse);
      expect(json.containsKey('companions'), isFalse);
      expect(json.containsKey('default_companion_id'), isFalse);
    });

    test('在场：没人回答就是 unknown，不是离线', () {
      final json = _golden('snapshot-healthy.json');
      if (json == null) {
        markTestSkipped('eidolon_sdk checkout 不在旁边');
        return;
      }
      final devices = parseMissionControlRuntime(json).devices.value;

      final live = devices.firstWhere((d) => d.deviceId == 'dev-esp32-living');
      expect(live.online, isTrue);
      expect(devicePresenceLabel(live), '在线');

      // 没有权威回答过它 —— 这既不是在线也不是故障。
      final web = devices.firstWhere((d) => d.deviceId == 'dev-web-body');
      expect(web.online, isFalse);
      expect(web.presenceUnobserved, isTrue);
      expect(devicePresenceLabel(web), '无人观测');
      expect(devicePresenceTone(web), CockpitTone.idle);

      // Hub 说它离线，那才是离线。
      final off =
          devices.firstWhere((d) => d.deviceId == 'dev-esp32-unclaimed');
      expect(devicePresenceLabel(off), '离线');
      expect(devicePresenceTone(off), CockpitTone.bad);
    });

    test('未探测的服务是未探测，不是正常', () {
      final json = _golden('snapshot-healthy.json');
      if (json == null) {
        markTestSkipped('eidolon_sdk checkout 不在旁边');
        return;
      }
      final services = parseMissionControlRuntime(json).services.value;
      final nats = services.firstWhere((s) => s.serviceId == 'nats');
      // 载荷里 online=true 但 checked=false —— 不能因此说它正常。
      expect(nats.checked, isFalse);
      expect(nats.stateLabel, '未探测');
      expect(nats.tone, CockpitTone.warn);
    });

    test('降级载荷：读不到的 lane 说读不到，读到的照常', () {
      final json = _golden('snapshot-degraded.json');
      if (json == null) {
        markTestSkipped('eidolon_sdk checkout 不在旁边');
        return;
      }
      final runtime = parseMissionControlRuntime(json);

      expect(runtime.memory.readable, isFalse);
      expect(runtime.memory.detail, contains('记忆服务'));
      expect(runtime.activities.readable, isFalse);
      expect(runtime.activities.value, isEmpty);

      // 降级但读到了：数据在，只是可能不全 —— 这一点必须能和「读不到」分开。
      expect(runtime.devices.state, LaneState.degraded);
      expect(runtime.devices.readable, isTrue);
      expect(runtime.devices.truncated, isTrue);
      expect(runtime.devices.value, isNotEmpty);

      // 一个源坏了不该让别的源变空。
      expect(runtime.services.healthy, isTrue);
      expect(runtime.services.value, isNotEmpty);
    });

    test('降级后的卫星说读不到，而不是空闲/未绑定', () {
      final json = _golden('snapshot-degraded.json');
      if (json == null) {
        markTestSkipped('eidolon_sdk checkout 不在旁边');
        return;
      }
      final runtime = parseMissionControlRuntime(json);
      final unit = CompanionUnit(
        companion: const CockpitCompanion(
          companionId: 'c',
          displayName: '砚舟',
          status: 'active',
          realmId: 'realm-1',
        ),
        devices: const <CockpitDevice>[],
        activities: const <CockpitActivity>[],
        turns: const <CockpitTurn>[],
        jobs: const <CockpitJob>[],
        bodiesReadable: runtime.devices.readable,
        activitiesReadable: runtime.activities.readable,
        recallReadable: runtime.turns.readable,
      );

      final activity = moonFacts(unit, MoonKind.act);
      expect(activity.value, '读不到');
      expect(activity.unreadable, isTrue);
      expect(activity.empty, isFalse, reason: '读不到不是空');
      expect(runtimeBadge(unit).text, '活动读不到');
    });
  });

  group('契约违反', () {
    test('版本或 coverage 不对就拒绝，不半懂着渲染', () {
      expect(
        () => parseMissionControlRuntime(<String, Object?>{
          'contract_version': '2',
          'coverage': 'owner-runtime',
          'generated_at': '2026-08-24T05:16:18Z',
        }),
        throwsA(isA<CockpitWireException>()),
      );
      expect(
        () => parseMissionControlRuntime(<String, Object?>{
          'contract_version': '1',
          'coverage': 'everything',
          'generated_at': '2026-08-24T05:16:18Z',
        }),
        throwsA(isA<CockpitWireException>()),
      );
    });

    test('lane 状态无法识别时按读不到处理，不按正常', () {
      expect(laneStateFromWire('something-new'), LaneState.unavailable);
      expect(laneStateFromWire(null), LaneState.unavailable);
      expect(laneStateFromWire('ok'), LaneState.ok);
    });

    test('unavailable 的 lane 即使带了 items 也不采用', () {
      final runtime = parseMissionControlRuntime(<String, Object?>{
        'contract_version': '1',
        'coverage': 'owner-runtime',
        'generated_at': '2026-08-24T05:16:18Z',
        'devices': {
          'state': 'unavailable',
          'detail': 'Hub 不可用',
          // 没被观测到的东西，不能因为躺在载荷里就被画出来。
          'items': [
            {
              'device_id': 'ghost',
              'presence': {'state': 'online', 'source': 'hub'},
            },
          ],
        },
        'activities': {'state': 'ok', 'items': <Object?>[]},
        'turns': {'state': 'ok', 'items': <Object?>[]},
        'jobs': {'state': 'ok', 'items': <Object?>[]},
        'memory': {'state': 'ok', 'value': null},
        'services': {'state': 'ok', 'items': <Object?>[]},
        'events': {'state': 'ok', 'items': <Object?>[]},
      });
      expect(runtime.devices.readable, isFalse);
      expect(runtime.devices.value, isEmpty);
      expect(runtime.devices.detail, 'Hub 不可用');
    });

    test('事件流的 reset 能被认出来', () {
      final json = _golden('events-live.json');
      if (json == null) {
        markTestSkipped('eidolon_sdk checkout 不在旁边');
        return;
      }
      final events = (json['events']! as List)
          .map((item) =>
              parseCockpitEvent(Map<String, Object?>.from(item as Map)))
          .toList();
      expect(events.where(isStreamReset), hasLength(1));
      expect(events.any((event) => event.origin == 'mock'), isFalse);
      // Each moment carries its own place in the Host's order, so a consumer
      // can tell which ones are new without asking a second function where the
      // one it just parsed came from.
      expect(events.first.ingestSeq, 10491);
    });
  });

  group('device_kind 不是设备种类', () {
    // 这条 wire 上的 `device_kind` 里放的是 Manifest 标识：Hub 把 `manifest_id`
    // 写进一个恰好叫 device_kind 的列（`hub/contracts/mappers.py`），Admin 原样
    // 投影出来（`local_api/management/mission_control.py:_row`）。schema 的描述
    // 和这份 golden 里的 `"web"` 都是旧说法，而键名是刻意不改的
    // （`docs/设备与Body/Manifest契约收敛.md` §8.3 ⑤）。所以消费侧的更正只有一个：
    // 不要把它当种类读。
    test('在场判定不看它 —— 两个方向都不看', () {
      final json = _golden('snapshot-healthy.json');
      if (json == null) {
        markTestSkipped('eidolon_sdk checkout 不在旁边');
        return;
      }
      // 给两台设备各换上一个恰好能骗过旧子串判定的 Manifest 标识：一台在线的
      // 摄像头，标识里带着 web；一台真正无人观测的身体，标识里不带。
      final patched = _patchDevice(
        _patchDevice(
          json,
          'dev-esp32-living',
          (device) => device['device_kind'] = 'eidolon-webcam-s3-v1',
        ),
        'dev-web-body',
        (device) => device['device_kind'] = 'eidolon-phone-body-v1',
      );
      final devices = parseMissionControlRuntime(patched).devices.value;

      // 旧判定会因为标识里没有 web 而把它读成离线。
      final unobserved = devices.firstWhere((d) => d.deviceId == 'dev-web-body');
      expect(unobserved.presenceUnobserved, isTrue);
      expect(devicePresenceLabel(unobserved), '无人观测');
      expect(devicePresenceTone(unobserved), CockpitTone.idle);
      // 字段照旧透传，只是按它真实的身份用。
      expect(unobserved.kind, 'eidolon-phone-body-v1');

      // 旧判定不会误伤这一台（它在线，先一步返回），但标识里的 web 也不该在
      // 任何地方变成一句关于形态的话。
      final live = devices.firstWhere((d) => d.deviceId == 'dev-esp32-living');
      expect(live.presenceUnobserved, isFalse);
      expect(devicePresenceLabel(live), '在线');
      expect(live.kind, 'eidolon-webcam-s3-v1');
    });

    test('权威回答了 unknown，和没有权威回答不是一回事', () {
      final json = _golden('snapshot-healthy.json');
      if (json == null) {
        markTestSkipped('eidolon_sdk checkout 不在旁边');
        return;
      }
      // 同一台设备，同样的 unknown，只是这一次 Hub 答了。`source` 的取值来自
      // schema 自己的词表。
      final answered = _patchDevice(json, 'dev-web-body', (device) {
        (device['presence']! as Map<String, Object?>)['source'] = 'hub';
      });
      final devices = parseMissionControlRuntime(answered).devices.value;
      final device = devices.firstWhere((d) => d.deviceId == 'dev-web-body');

      expect(device.presenceUnobserved, isFalse);
      expect(devicePresenceLabel(device), '未探测');
      expect(devicePresenceTone(device), CockpitTone.idle);
    });

    test('离线仍然是离线 —— 那是有人回答的', () {
      final json = _golden('snapshot-healthy.json');
      if (json == null) {
        markTestSkipped('eidolon_sdk checkout 不在旁边');
        return;
      }
      final patched = _patchDevice(
        json,
        'dev-esp32-unclaimed',
        (device) => device['device_kind'] = 'eidolon-web-console-v1',
      );
      final devices = parseMissionControlRuntime(patched).devices.value;
      final off =
          devices.firstWhere((d) => d.deviceId == 'dev-esp32-unclaimed');

      expect(off.presenceUnobserved, isFalse);
      expect(devicePresenceLabel(off), '离线');
      expect(devicePresenceTone(off), CockpitTone.bad);
    });
  });
}
