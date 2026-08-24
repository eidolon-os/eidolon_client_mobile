import 'package:flutter/material.dart';

import 'cockpit_models.dart';
import 'cockpit_theme.dart';

/// What the focused companion is, in the space above the deck.
///
/// The console puts this in a side rail; a phone has no side, so it sits over
/// the lower map and the camera flies the focused planet above it. Selecting a
/// moon switches the tab in place rather than pushing a page: losing your place
/// in the constellation to read one number is the thing this avoids.
enum InspectorTab { overview, body, memory, activity }

InspectorTab tabForMoon(MoonKind kind) => switch (kind) {
      MoonKind.body => InspectorTab.body,
      MoonKind.mem => InspectorTab.memory,
      MoonKind.act => InspectorTab.activity,
    };

MoonKind? moonForTab(InspectorTab tab) => switch (tab) {
      InspectorTab.overview => null,
      InspectorTab.body => MoonKind.body,
      InspectorTab.memory => MoonKind.mem,
      InspectorTab.activity => MoonKind.act,
    };

class CompanionInspectorCard extends StatelessWidget {
  const CompanionInspectorCard({
    super.key,
    required this.unit,
    required this.tab,
    required this.onTab,
    required this.onClose,
    required this.onDetails,
  });

  final CompanionUnit unit;
  final InspectorTab tab;
  final void Function(InspectorTab tab) onTab;
  final VoidCallback onClose;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) => CockpitSlab(
        accent: unit.isPrimary ? Cockpit.sun : Cockpit.cyan,
        borderOpacity: 0.5,
        notch: 14,
        fill: const Color(0xFF07030F).withValues(alpha: 0.94),
        padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CockpitLed(
                  color: toneColor(
                    companionLifecycleTone(unit.companion.status),
                  ),
                  size: 7,
                ),
                const SizedBox(width: 7),
                Text(
                  'COMPANION FOCUS',
                  style: Cockpit.mono(
                      size: 8.5, color: Cockpit.inkDim, tracking: 0.12),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: onClose,
                  child: Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Cockpit.inkDim.withValues(alpha: 0.5),
                      ),
                    ),
                    child: const Text(
                      '×',
                      style: TextStyle(
                        fontSize: 15,
                        height: 1,
                        color: Cockpit.inkDim,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(unit.name, style: Cockpit.sans(size: 19)),
                const SizedBox(width: 7),
                if (unit.isPrimary)
                  Text(
                    '★ 主伙伴',
                    style: Cockpit.mono(size: 9, color: Cockpit.sun),
                  )
                else
                  Text(
                    unit.companion.kind,
                    style: Cockpit.mono(size: 9, color: Cockpit.inkDim),
                  ),
              ],
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                for (final item in <(InspectorTab, String, String)>[
                  (InspectorTab.overview, '概览', '◉'),
                  (InspectorTab.body, '身体', '⬡'),
                  (InspectorTab.memory, '记忆', '◈'),
                  (InspectorTab.activity, '活动', '⚡'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: GestureDetector(
                      onTap: () => onTab(item.$1),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: tab == item.$1
                                ? Cockpit.cyan
                                : Cockpit.cyan.withValues(alpha: 0.18),
                          ),
                          color: tab == item.$1
                              ? Cockpit.cyan.withValues(alpha: 0.12)
                              : null,
                        ),
                        child: Row(
                          children: [
                            Text(
                              item.$3,
                              style: TextStyle(
                                fontSize: 11,
                                height: 1,
                                color: tab == item.$1
                                    ? Cockpit.cyan
                                    : Cockpit.inkDim,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              item.$2,
                              style: Cockpit.mono(
                                size: 10,
                                color: tab == item.$1
                                    ? Cockpit.cyan
                                    : Cockpit.inkDim,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            AnimatedSize(
              duration: Cockpit.base,
              curve: Cockpit.easeOut,
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: double.infinity,
                child: switch (tab) {
                  InspectorTab.overview => _Overview(unit: unit),
                  InspectorTab.body => _Bodies(unit: unit),
                  InspectorTab.memory => _Memory(unit: unit),
                  InspectorTab.activity => _Activities(unit: unit),
                },
              ),
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                Text(
                  '只读聚焦',
                  style: Cockpit.mono(
                    size: 9,
                    weight: FontWeight.w600,
                    color: Cockpit.inkDim,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: onDetails,
                  child: Text(
                    '完整详情 ↗',
                    style: Cockpit.mono(size: 10, color: Cockpit.cyan),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

class _Overview extends StatelessWidget {
  const _Overview({required this.unit});

  final CompanionUnit unit;

  @override
  Widget build(BuildContext context) {
    final active = unit.activities.where(isActiveActivity).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _Hero(
              label: '身体',
              value: '${unit.onlineDevices}/${unit.devices.length}',
              note: '在线',
              tone: unit.onlineDevices > 0 ? CockpitTone.ok : CockpitTone.idle,
            ),
            _Hero(
              label: '记忆',
              value: memoryRealmStateLabel(unit.realm),
              tone: unit.realm.isEmpty ? CockpitTone.idle : CockpitTone.ok,
            ),
            _Hero(
              label: '活动',
              value: '${active == 0 ? unit.activities.length : active}',
              note: active == 0 ? '记录' : '进行中',
              tone: active == 0 ? CockpitTone.idle : CockpitTone.live,
            ),
          ],
        ),
        const SizedBox(height: 9),
        _Facts(
          rows: <(String, String)>[
            ('基因 genome', genomeStateLabel(unit.genome)),
            ('记忆召回', '${unit.companion.recallHits ?? '—'}'),
            (
              '后台整理',
              unit.companion.runners.isEmpty ? '—' : unit.companion.runners
            ),
            (
              '写入策略',
              unit.companion.writeDisposition.isEmpty
                  ? '—'
                  : unit.companion.writeDisposition
            ),
          ],
        ),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.label,
    required this.value,
    required this.tone,
    this.note,
  });

  final String label;
  final String value;
  final CockpitTone tone;
  final String? note;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Cockpit.mono(size: 8.5, color: Cockpit.inkDim)),
            const SizedBox(height: 3),
            Text(
              value,
              style: Cockpit.mono(
                size: 15,
                weight: FontWeight.w900,
                color: toneColor(tone),
              ),
            ),
            if (note case final tail?) ...[
              const SizedBox(height: 2),
              Text(
                tail,
                style: Cockpit.mono(
                  size: 8.5,
                  weight: FontWeight.w600,
                  color: Cockpit.inkDim,
                ),
              ),
            ],
          ],
        ),
      );
}

class _Facts extends StatelessWidget {
  const _Facts({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
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
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Text(
                      row.$1,
                      style: Cockpit.mono(size: 9.5, color: Cockpit.inkDim),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        row.$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: Cockpit.mono(size: 10.5),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
}

class _Bodies extends StatelessWidget {
  const _Bodies({required this.unit});

  final CompanionUnit unit;

  @override
  Widget build(BuildContext context) {
    if (unit.devices.isEmpty) {
      return Text(
        '尚未绑定身体。这个伙伴还没有可以说话、可以被看见的入口。',
        style: Cockpit.mono(
          size: 10,
          weight: FontWeight.w600,
          color: Cockpit.inkDim,
          height: 1.6,
        ),
      );
    }
    return Column(
      children: [
        for (final device in unit.devices)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                CockpitLed(
                    color: toneColor(devicePresenceTone(device)), size: 6),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        deviceShortName(device),
                        style: Cockpit.sans(size: 12, weight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${deviceTypeLabel(device)} · ${device.role.isEmpty ? device.kind : device.role}',
                        style: Cockpit.mono(size: 9, color: Cockpit.inkDim),
                      ),
                    ],
                  ),
                ),
                Text(
                  devicePresenceLabel(device),
                  style: Cockpit.mono(
                    size: 10,
                    color: toneColor(devicePresenceTone(device)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Memory extends StatelessWidget {
  const _Memory({required this.unit});

  final CompanionUnit unit;

  @override
  Widget build(BuildContext context) {
    final configured = unit.realm.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            border: Border.all(
              color: (configured ? Cockpit.yellow : Cockpit.inkDim)
                  .withValues(alpha: 0.45),
            ),
            color: configured
                ? Cockpit.yellow.withValues(alpha: 0.06)
                : Colors.transparent,
          ),
          child: Row(
            children: [
              Text(
                '◈',
                style: TextStyle(
                  fontSize: 17,
                  height: 1,
                  color: configured ? Cockpit.yellow : Cockpit.inkDim,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  configured ? '伙伴记忆域已连接' : '尚未开通记忆空间',
                  style: Cockpit.sans(
                    size: 12,
                    weight: FontWeight.w700,
                    color: configured ? Cockpit.ink : Cockpit.inkDim,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 9),
        _Facts(
          rows: <(String, String)>[
            ('召回命中', '${unit.companion.recallHits ?? '—'}'),
            (
              '后台整理',
              unit.companion.runners.isEmpty ? '—' : unit.companion.runners
            ),
            (
              '写入策略',
              unit.companion.writeDisposition.isEmpty
                  ? '—'
                  : unit.companion.writeDisposition
            ),
            ('记忆域', configured ? compactId(unit.realm) : '未开通'),
          ],
        ),
      ],
    );
  }
}

class _Activities extends StatelessWidget {
  const _Activities({required this.unit});

  final CompanionUnit unit;

  @override
  Widget build(BuildContext context) {
    if (unit.activities.isEmpty) {
      return Text(
        '当前没有活动记录。',
        style: Cockpit.mono(
          size: 10,
          weight: FontWeight.w600,
          color: Cockpit.inkDim,
        ),
      );
    }
    return Column(
      children: [
        for (final activity in unit.activities.take(4))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                CockpitLed(
                    color: toneColor(statusTone(activity.status)), size: 6),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        activityKindLabel(activity.kind),
                        style: Cockpit.sans(size: 12, weight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        activity.summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Cockpit.mono(size: 9, color: Cockpit.inkDim),
                      ),
                    ],
                  ),
                ),
                Text(
                  activityStatusLabel(activity.status),
                  style: Cockpit.mono(
                    size: 10,
                    color: toneColor(statusTone(activity.status)),
                  ),
                ),
              ],
            ),
          ),
        if (unit.activeVoiceTurn case final turn?)
          Row(
            children: [
              const CockpitLed(color: Cockpit.cyan, size: 6),
              const SizedBox(width: 8),
              Text(
                '当前对话 · ${formatLatency(turn.latencyMs)} · 召回 ${turn.memoryHits}',
                style: Cockpit.mono(size: 10, color: Cockpit.cyan),
              ),
            ],
          ),
      ],
    );
  }
}
