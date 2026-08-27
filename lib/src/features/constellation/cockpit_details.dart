import '../../protocol/companion_contract.dart';
import 'package:flutter/material.dart';

import 'cockpit_models.dart';
import 'cockpit_theme.dart';

/// The drill-downs: one sheet per thing you can tap.
///
/// Each says what it knows and, where it matters, what it does not. Presence is
/// the recurring trap — nothing in this system publishes a heartbeat for a
/// companion, so no sheet here claims one is "online"; a body's presence is a
/// body's, and it is labelled as such.
Future<void> showCockpitSheet(
  BuildContext context, {
  required String title,
  required String kicker,
  required Widget child,
  Color accent = Cockpit.cyan,
}) =>
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.3,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, controller) => DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF07030F).withValues(alpha: 0.97),
            border:
                Border(top: BorderSide(color: accent.withValues(alpha: 0.5))),
          ),
          child: Column(
            children: [
              Container(
                width: 46,
                height: 3,
                margin: const EdgeInsets.symmetric(vertical: 9),
                color: Cockpit.inkDim.withValues(alpha: 0.5),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: Text(title, style: Cockpit.sans(size: 18))),
                    Text(
                      kicker,
                      style:
                          Cockpit.mono(size: 9, color: accent, tracking: 0.1),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 28),
                  children: [child],
                ),
              ),
            ],
          ),
        ),
      ),
    );

/// A label / value table. The one shape every detail sheet is built from, so a
/// reader learns to read it once.
class FactTable extends StatelessWidget {
  const FactTable({super.key, required this.rows, this.title});

  final List<(String, String)> rows;
  final String? title;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title case final heading?) ...[
            Text(
              heading,
              style:
                  Cockpit.mono(size: 9.5, color: Cockpit.inkDim, tracking: 0.1),
            ),
            const SizedBox(height: 7),
          ],
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: Cockpit.hair),
                bottom: BorderSide(color: Cockpit.hair),
              ),
            ),
            child: Column(
              children: [
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 92,
                          child: Text(
                            row.$1,
                            style:
                                Cockpit.mono(size: 9.5, color: Cockpit.inkDim),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            row.$2,
                            textAlign: TextAlign.right,
                            style: Cockpit.mono(size: 10.5, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
}

class SheetNote extends StatelessWidget {
  const SheetNote(
      {super.key, required this.text, this.tone = CockpitTone.idle});

  final String text;
  final CockpitTone tone;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          text,
          style: Cockpit.mono(
            size: 9.5,
            weight: FontWeight.w600,
            color: toneColor(tone),
            height: 1.65,
          ),
        ),
      );
}

Widget ownerSheetBody(CockpitSnapshot snapshot) {
  final devices = snapshot.devices;
  final online = devices.where((device) => device.online).length;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '这台主机的主权域：伙伴、身体与记忆都归属于这一个主人，身份留在内核，'
        '身体只是接入的入口。',
        style: Cockpit.sans(
          size: 12.5,
          weight: FontWeight.w500,
          color: Cockpit.ink,
          height: 1.6,
        ),
      ),
      const SizedBox(height: 14),
      FactTable(
        title: '归属',
        rows: <(String, String)>[
          ('主人', snapshot.owner.displayName),
          ('伙伴', '${snapshot.companions.length} 位'),
          ('身体', '${devices.length} 台 · $online 在线'),
          ('待认领', '${snapshot.unboundDevices.length} 台'),
          ('记忆空间', '${snapshot.memory.realmsTotal} 个'),
          (
            '后台整理',
            '${snapshot.memory.runnersOnline}/${snapshot.memory.runnersTotal} 在线'
          ),
        ],
      ),
      const SizedBox(height: 12),
      FactTable(
        title: '伙伴',
        rows: <(String, String)>[
          for (final companion in snapshot.companions)
            (
              companion.displayName.isEmpty
                  ? compactId(companion.companionId)
                  : companion.displayName,
              '${snapshot.defaultCompanionId == companion.companionId ? '默认 · ' : ''}'
                  '${companionLifecycleLabel(companion.status)}'
                  ' · 记忆${memoryRealmStateLabel(companion.realmId)}'
            ),
        ],
      ),
      const SheetNote(
        text: '这一屏不说伙伴是否在线：这套系统没有为伙伴发布过任何心跳，'
            '一个没人喂的绿点比没有绿点更糟。身体的在场是身体的，已按台标注。',
      ),
    ],
  );
}

Widget serviceSheetBody(CockpitService service) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          service.role,
          style: Cockpit.sans(
            size: 12.5,
            weight: FontWeight.w500,
            color: Cockpit.ink,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 14),
        FactTable(
          rows: <(String, String)>[
            ('代码', service.code),
            ('接入方式', service.mode),
            (
              '层次',
              switch (service.tier) {
                ServiceTier.service => '子项目服务',
                ServiceTier.middleware => '共享基础设施',
                ServiceTier.external => '外挂扩展',
              }
            ),
            ('状态', service.stateLabel),
            ('延迟', formatLatency(service.latencyMs)),
            ('细节', service.detail.isEmpty ? '—' : service.detail),
          ],
        ),
        if (!service.checked)
          const SheetNote(
            text: '没有人探测过它。这不是「正常」，是「不知道」。',
            tone: CockpitTone.warn,
          )
        else if (!service.online)
          SheetNote(
            text:
                '它没有回应。${service.tier == ServiceTier.external ? '这是外挂扩展，核心链路不依赖它。' : '依赖它的链路会降级。'}',
            tone: CockpitTone.bad,
          ),
      ],
    );

/// One activity, opened.
///
/// [turn] is the interaction this activity is, when there is one — the route
/// says which nodes it passed through, and the turn says how long each part of
/// the thinking took. Both were on the Host all along; the second was read by
/// nothing, so 「哪一段慢」 could not be answered from any screen.
Widget activitySheetBody(
  CockpitActivity activity,
  String companionName, {
  CockpitTurn? turn,
}) {
  final current = currentActivityHop(activity);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        activity.summary,
        style: Cockpit.sans(
          size: 12.5,
          weight: FontWeight.w500,
          color: Cockpit.ink,
          height: 1.6,
        ),
      ),
      const SizedBox(height: 14),
      FactTable(
        rows: <(String, String)>[
          ('种类', activityKindLabel(activity.kind)),
          ('伙伴', companionName.isEmpty ? '—' : companionName),
          ('状态', activityStatusLabel(activity.status)),
          ('结果', activity.outcome),
          if (activity.turnId.isNotEmpty) ('对话轮次', compactId(activity.turnId)),
          if (activity.originDeviceId.isNotEmpty)
            ('来源身体', compactId(activity.originDeviceId)),
          if (turn != null) ('这轮召回', '${turn.memoryHits} 条'),
          if (turn != null && turn.toolNames.isNotEmpty)
            ('用到的工具', turn.toolNames.join('、')),
        ],
      ),
      if (turn != null && turn.breakdown.isNotEmpty) ...[
        const SizedBox(height: 14),
        _Breakdown(phases: turn.breakdown, totalMs: turn.latencyMs),
      ],
      const SizedBox(height: 14),
      Text(
        '事实链路 · ${activity.route.length} 个节点',
        style: Cockpit.mono(size: 9.5, color: Cockpit.inkDim, tracking: 0.1),
      ),
      const SizedBox(height: 8),
      for (var index = 0; index < activity.route.length; index += 1)
        _RouteRow(
          index: index,
          hop: activity.route[index],
          current: current?.hopId == activity.route[index].hopId,
        ),
      if (activity.route.isEmpty) const SheetNote(text: '这条活动还没有留下可以展开的节点。'),
    ],
  );
}

class _RouteRow extends StatelessWidget {
  const _RouteRow({
    required this.index,
    required this.hop,
    required this.current,
  });

  final int index;
  final CockpitHop hop;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final tone = toneColor(statusTone(hop.status));
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        border: Border.all(
          color: current ? Cockpit.cyan : Cockpit.hair,
        ),
        color: current ? Cockpit.cyan.withValues(alpha: 0.07) : null,
      ),
      child: Row(
        children: [
          Text(
            (index + 1).toString().padLeft(2, '0'),
            style: Cockpit.mono(size: 10, color: Cockpit.inkDim),
          ),
          const SizedBox(width: 9),
          CockpitLed(color: current ? Cockpit.cyan : tone, size: 6),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hop.label,
                  style: Cockpit.sans(size: 12, weight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '${hop.stage.isEmpty ? hop.nodeType : hop.stage} · ${hop.status}',
                  style: Cockpit.mono(size: 9, color: Cockpit.inkDim),
                ),
              ],
            ),
          ),
          Text(
            formatLatency(hop.latencyMs),
            style: Cockpit.mono(size: 10, color: Cockpit.inkDim),
          ),
        ],
      ),
    );
  }
}

Widget eventSheetBody(CockpitEvent event, {String companionName = ''}) =>
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          event.summary,
          style: Cockpit.sans(
            size: 12.5,
            weight: FontWeight.w500,
            color: Cockpit.ink,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 14),
        FactTable(
          rows: <(String, String)>[
            ('时间', formatClock(event.ts)),
            ('来源', event.source),
            ('类型', event.type),
            ('严重度', event.severity),
            ('结果', event.outcome),
            ('来路', event.origin),
            if (companionName.isNotEmpty) ('伙伴', companionName),
            if (event.deviceId.isNotEmpty) ('身体', compactId(event.deviceId)),
            if (event.milestone.isNotEmpty) ('阶段', event.milestone),
            if (event.turnId.isNotEmpty) ('对话轮次', compactId(event.turnId)),
          ],
        ),
        if (event.origin == 'mock')
          const SheetNote(
            text: '这条事件来自演示数据，不是这台主机说的。',
            tone: CockpitTone.warn,
          ),
      ],
    );

Widget deviceSheetBody(CockpitDevice device, {String companionName = ''}) =>
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '身体是入口，不是身份。它接入的是主人的域，撤掉它不会带走任何归属。',
          style: Cockpit.sans(
            size: 12.5,
            weight: FontWeight.w500,
            color: Cockpit.ink,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 14),
        FactTable(
          rows: <(String, String)>[
            ('名称', deviceShortName(device)),
            ('形态', deviceTypeLabel(device)),
            ('硬件', device.kind),
            ('角色', device.role.isEmpty ? '—' : device.role),
            ('在场', devicePresenceLabel(device)),
            ('归属伙伴', companionName.isEmpty ? '未绑定' : companionName),
            ('标识', compactId(device.deviceId, maxLength: 26)),
            if (device.capabilities.isNotEmpty)
              ('能力', device.capabilities.join('、')),
          ],
        ),
        if (device.preparedWebBody)
          const SheetNote(
            text: '这是一个已经备好、但还没有附身的 Web 身体。既不是在线，也不是故障。',
          ),
      ],
    );

Widget companionSheetBody(CompanionUnit unit) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '虚拟伙伴（agent），归属于这台主机的主人。它拥有自己的身体、记忆与活动。',
          style: Cockpit.sans(
            size: 12.5,
            weight: FontWeight.w500,
            color: Cockpit.ink,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 14),
        FactTable(
          title: '身份',
          rows: <(String, String)>[
            ('名字', unit.name),
            ('角色', unit.isDefault ? '默认' : unit.companion.kind),
            ('生命周期', companionLifecycleLabel(unit.companion.status)),
            ('基因 genome', genomeStateLabel(unit.genome)),
            ('记忆空间', memoryRealmStateLabel(unit.realm)),
          ],
        ),
        const SizedBox(height: 12),
        FactTable(
          title: '身体',
          rows: <(String, String)>[
            if (unit.devices.isEmpty)
              ('—', '尚未绑定')
            else
              for (final device in unit.devices)
                (deviceShortName(device), devicePresenceLabel(device)),
          ],
        ),
        const SizedBox(height: 12),
        FactTable(
          title: '活动',
          rows: <(String, String)>[
            if (unit.activities.isEmpty)
              ('—', '没有记录')
            else
              for (final activity in unit.activities.take(6))
                (
                  activityKindLabel(activity.kind),
                  activityStatusLabel(activity.status)
                ),
          ],
        ),
        if (unit.jobs.isNotEmpty) ...[
          const SizedBox(height: 12),
          FactTable(
            title: '后台任务',
            rows: <(String, String)>[
              for (final job in unit.jobs) (job.kind, job.status),
            ],
          ),
        ],
      ],
    );

/// Where a turn's time went.
///
/// The bar is the share of the turn, so a glance answers 「哪一段慢」 without
/// reading six numbers. A phase the turn never reached shows 「没走到」 rather
/// than a zero: the shape of a turn includes the steps it did not get to, and a
/// zero would read as a step that was instant.
class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.phases, required this.totalMs});

  final List<CockpitTurnPhase> phases;
  final int? totalMs;

  @override
  Widget build(BuildContext context) {
    // The share is taken against the largest measured phase, not against the
    // turn's total: the phases overlap (tools run inside the generation) and
    // they do not have to sum to it, so bars drawn against the total would
    // quietly claim a completeness this data does not have.
    final measured = phases
        .map((phase) => phase.latencyMs)
        .whereType<int>()
        .fold<int>(0, (a, b) => a > b ? a : b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          totalMs == null
              ? '时间去哪了'
              : '时间去哪了 · 这轮共 ${formatLatency(totalMs)}',
          style: Cockpit.mono(size: 9.5, color: Cockpit.inkDim, tracking: 0.1),
        ),
        const SizedBox(height: 8),
        for (final phase in phases)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              children: [
                SizedBox(
                  width: 132,
                  child: Text(
                    phase.label,
                    style: Cockpit.sans(size: 11, color: Cockpit.ink),
                    maxLines: 2,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Share(
                    latencyMs: phase.latencyMs,
                    against: measured,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 58,
                  child: Text(
                    phase.latencyMs == null
                        ? '没走到'
                        : formatLatency(phase.latencyMs),
                    textAlign: TextAlign.right,
                    style: Cockpit.mono(
                      size: 10,
                      color: phase.latencyMs == null
                          ? Cockpit.inkDim
                          : Cockpit.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Share extends StatelessWidget {
  const _Share({required this.latencyMs, required this.against});

  final int? latencyMs;
  final int against;

  @override
  Widget build(BuildContext context) {
    final value = latencyMs;
    if (value == null || against <= 0) {
      return const SizedBox(height: 4);
    }
    return LayoutBuilder(
      builder: (context, size) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          height: 4,
          width: (size.maxWidth * (value / against)).clamp(1.0, size.maxWidth),
          color: Cockpit.cyan.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}
