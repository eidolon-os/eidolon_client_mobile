import 'package:eidolon_client_mobile/src/features/constellation/cockpit_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The console cockpit and this one must agree about what a fact means. These
/// pin the mappings, because a phone that quietly calls "denied" a success is
/// worse than one that cannot draw it.

CockpitEvent _event({
  String source = 'channel',
  String type = 'channel.turn.speech',
  String milestone = '',
  String severity = 'info',
  String outcome = 'success',
}) =>
    CockpitEvent(
      eventId: 'e1',
      ts: DateTime.utc(2026, 8, 24, 10),
      source: source,
      type: type,
      summary: '摘要',
      severity: severity,
      outcome: outcome,
      milestone: milestone,
    );

void main() {
  group('event → 有方向的脉冲', () {
    test('Hub 的事件从身体流向大脑', () {
      final pulse =
          eventToPulse(_event(source: 'hub', type: 'hub.device.joined'))!;
      expect(pulse.leg, MoonKind.body);
      expect(pulse.direction, PulseDirection.inward);
    });

    test('阶段优先于来源：channel 在发起推理时走活动腿', () {
      final pulse = eventToPulse(_event(milestone: 'generating'))!;
      expect(pulse.leg, MoonKind.act);
      expect(pulse.direction, PulseDirection.outward);
    });

    test('第一段音频是从大脑回到身体', () {
      final pulse = eventToPulse(_event(milestone: 'first_audio'))!;
      expect(pulse.leg, MoonKind.body);
      expect(pulse.direction, PulseDirection.outward);
    });

    test('召回请求出去，召回结果回来', () {
      final out = eventToPulse(
        _event(source: 'memory', type: 'memory.recall.requested'),
      )!;
      final back = eventToPulse(
        _event(source: 'memory', type: 'memory.recall.recalled'),
      )!;
      expect(out.direction, PulseDirection.outward);
      expect(back.direction, PulseDirection.inward);
      expect(out.leg, MoonKind.mem);
    });

    test('不碰任何一条腿的来源不发脉冲', () {
      expect(eventToPulse(_event(source: 'admin', type: 'admin.x')), isNull);
      expect(eventToPulse(_event(source: 'data', type: 'data.x')), isNull);
    });
  });

  group('脉冲色调', () {
    test('失败或 error 走告警色', () {
      expect(eventTone('info', 'failure'), PulseTone.bad);
      expect(eventTone('error', 'success'), PulseTone.bad);
    });

    test('被拒绝或 warn 走注意色', () {
      expect(eventTone('info', 'denied'), PulseTone.warn);
      expect(eventTone('warn', 'success'), PulseTone.warn);
    });

    test('成功和延后都算正常', () {
      expect(eventTone('info', 'success'), PulseTone.normal);
      expect(eventTone('info', 'deferred'), PulseTone.normal);
    });
  });

  group('循环腿', () {
    CompanionUnit unit({
      bool online = true,
      int memoryHits = 0,
      bool active = true,
    }) =>
        CompanionUnit(
          companion: const CockpitCompanion(
            companionId: 'a',
            displayName: '砚舟',
            status: 'active',
          ),
          devices: [
            CockpitDevice(
              deviceId: 'd1',
              name: '身体',
              kind: 'esp32',
              status: online ? 'active' : 'offline',
              online: online,
              companionId: 'a',
            ),
          ],
          activities: active
              ? const [
                  CockpitActivity(
                    activityId: 'act',
                    kind: 'voice_turn',
                    companionId: 'a',
                    status: 'running',
                    summary: '对话',
                  ),
                ]
              : const <CockpitActivity>[],
          turns: [
            CockpitTurn(
              turnId: 't1',
              companionId: 'a',
              status: 'running',
              memoryHits: memoryHits,
            ),
          ],
          jobs: const <CockpitJob>[],
        );

    test('身体腿跟着在场，不跟着绑定', () {
      expect(flowLegs(unit()).body, isTrue);
      expect(flowLegs(unit(online: false)).body, isFalse);
    });

    test('零次召回不点亮记忆腿', () {
      expect(flowLegs(unit()).mem, isFalse);
      expect(flowLegs(unit()).memBright, 0);
    });

    test('召回越多记忆腿越亮，一次也看得见', () {
      final one = flowLegs(unit(memoryHits: 1));
      final many = flowLegs(unit(memoryHits: 12));
      expect(one.mem, isTrue);
      expect(one.memBright, greaterThanOrEqualTo(0.45));
      expect(many.memBright, 1);
      expect(many.memBright, greaterThan(one.memBright));
    });

    test('没有活动就不循环', () {
      expect(flowLegs(unit(active: false)).act, isFalse);
    });
  });

  group('是否循环', () {
    test('被聚焦的伙伴总是循环', () {
      expect(
        shouldFlow(
          companionId: 'a',
          focusedId: 'a',
          hasActivity: true,
          activeCount: 9,
        ),
        isTrue,
      );
    });

    test('同时活跃的少时未聚焦的也循环', () {
      expect(
        shouldFlow(
          companionId: 'a',
          focusedId: '',
          hasActivity: true,
          activeCount: autoFlowMax,
        ),
        isTrue,
      );
    });

    test('活跃的多了就退回节点呼吸，避免满屏乱跑', () {
      expect(
        shouldFlow(
          companionId: 'a',
          focusedId: 'b',
          hasActivity: true,
          activeCount: autoFlowMax + 1,
        ),
        isFalse,
      );
    });

    test('没有活动的伙伴永远不循环', () {
      expect(
        shouldFlow(
          companionId: 'a',
          focusedId: 'a',
          hasActivity: false,
          activeCount: 0,
        ),
        isFalse,
      );
    });
  });

  group('阶段 → 卫星', () {
    test('收音落在身体，召回落在记忆，推理落在活动', () {
      expect(stageMoon('input'), MoonKind.body);
      expect(stageMoon('playback'), MoonKind.body);
      expect(stageMoon('memory_recall'), MoonKind.mem);
      expect(stageMoon('memory_write'), MoonKind.mem);
      expect(stageMoon('agent_turn'), MoonKind.act);
      expect(stageMoon('tools'), MoonKind.act);
    });

    test('不认识的阶段不乱点灯', () {
      expect(stageMoon('something-new'), isNull);
      expect(stageMoon(''), isNull);
    });

    test('当前阶段取正在跑的那一段，否则取最后完成的', () {
      const running = CockpitTurn(
        turnId: 't',
        companionId: 'a',
        status: 'running',
        stages: [
          CockpitTurnStage(key: 'input', label: '输入', status: 'done'),
          CockpitTurnStage(key: 'agent_turn', label: '推理', status: 'running'),
        ],
      );
      const settled = CockpitTurn(
        turnId: 't',
        companionId: 'a',
        status: 'completed',
        stages: [
          CockpitTurnStage(key: 'input', label: '输入', status: 'done'),
          CockpitTurnStage(key: 'tts', label: '合成', status: 'done'),
        ],
      );
      expect(currentStageKey(running), 'agent_turn');
      expect(currentStageKey(settled), 'tts');
      expect(currentStageKey(null), '');
    });
  });

  group('身体在场', () {
    CockpitDevice device({
      bool online = false,
      String status = 'active',
      bool prepared = false,
      String kind = 'esp32',
    }) =>
        CockpitDevice(
          deviceId: 'd',
          name: '',
          kind: kind,
          status: status,
          online: online,
          preparedWebBody: prepared,
        );

    test('备好的 Web 身体既不是在线也不是故障', () {
      final prepared = device(kind: 'web', prepared: true);
      expect(devicePresenceLabel(prepared), '已准备');
      expect(devicePresenceTone(prepared), CockpitTone.idle);
    });

    test('离线是故障色，未探测是未知', () {
      expect(devicePresenceTone(device(status: 'offline')), CockpitTone.bad);
      expect(devicePresenceLabel(device(status: 'unknown')), '未探测');
      expect(devicePresenceTone(device(status: 'unknown')), CockpitTone.idle);
    });

    test('形态只看硬件，不看角色', () {
      expect(deviceTypeLabel(device(kind: 'web')), '虚拟身体');
      expect(deviceTypeLabel(device(kind: 'raspberry-pi5')), '物理身体');
      expect(deviceTypeLabel(device(kind: 'unknown')), '设备');
    });

    test('没有名字时退回可读的尾号，而不是甩一串标识', () {
      const mac = CockpitDevice(
        deviceId: '10:51:db:7e:24:44',
        name: '',
        kind: 'esp32',
        status: 'active',
        online: true,
      );
      expect(deviceShortName(mac), '尾号 24:44');
    });
  });

  group('状态与服务', () {
    test('状态映射到四种色调', () {
      expect(statusTone('completed'), CockpitTone.ok);
      expect(statusTone('running'), CockpitTone.warn);
      expect(statusTone('failed'), CockpitTone.bad);
      expect(statusTone('whatever'), CockpitTone.idle);
    });

    test('没人探测过的服务是未知，不是正常', () {
      const unprobed = CockpitService(
        serviceId: 's',
        name: '服务',
        code: 'code',
        role: '',
        mode: '托管',
        tier: ServiceTier.service,
        glyph: '◊',
        online: true,
        checked: false,
      );
      expect(unprobed.stateLabel, '未探测');
      expect(unprobed.tone, CockpitTone.warn);
    });
  });

  test('延迟格式在秒和毫秒之间切换，未知就是未知', () {
    expect(formatLatency(null), '—');
    expect(formatLatency(180), '180ms');
    expect(formatLatency(1250), '1.25s');
  });
}
