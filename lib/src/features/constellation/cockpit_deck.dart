import 'package:flutter/material.dart';

import 'cockpit_models.dart';
import 'cockpit_theme.dart';

/// How tall the collapsed rail is. Shared so anything floating above it can
/// clear it without measuring.
const double kDeckHeight = 122;

/// The runtime backplane, along the bottom edge.
///
/// Collapsed it is one rail: which substrate services answered, and the last
/// thing that happened. That is the pair a phone can honestly hold at a glance.
/// Everything else — the full activity routes, the event log, per-service
/// detail — is one tap away in a sheet, rather than crammed in at four pixels.
///
/// A service nobody probed is shown as unprobed, not as healthy. This rail has
/// no notion of "presumed fine".
class KernelDeck extends StatelessWidget {
  const KernelDeck({
    super.key,
    required this.snapshot,
    required this.onExpand,
    required this.onServiceTap,
    required this.onEventTap,
    this.height = kDeckHeight,
  });

  final CockpitSnapshot snapshot;
  final VoidCallback onExpand;
  final void Function(CockpitService service) onServiceTap;
  final void Function(CockpitEvent event) onEventTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    final services = snapshot.services;
    final online = services.where((service) => service.online).length;
    final live = snapshot.pipelineActive;
    final latest = snapshot.events.isEmpty ? null : snapshot.events.first;

    return Container(
      height: height + MediaQuery.paddingOf(context).bottom,
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      decoration: BoxDecoration(
        color: Cockpit.panel,
        border: Border(
          top: BorderSide(
            color: (live ? Cockpit.cyan : Cockpit.hair)
                .withValues(alpha: live ? 0.5 : 0.16),
          ),
        ),
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: onExpand,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding:
                  const EdgeInsets.only(left: 12, right: 10, top: 7, bottom: 5),
              child: Row(
                children: [
                  CockpitLed(
                    color: live ? Cockpit.ok : Cockpit.idle,
                    size: 7,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    'LIVE KERNEL',
                    style: Cockpit.mono(size: 9.5, tracking: 0.12),
                  ),
                  const SizedBox(width: 7),
                  // Gives way first on a narrow phone: the subtitle is the one
                  // thing in this row that is decoration rather than state.
                  Flexible(
                    child: Text(
                      '主权内核运行背板',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Cockpit.mono(
                        size: 9.5,
                        weight: FontWeight.w600,
                        color: Cockpit.inkDim,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'CORE $online/${services.length}',
                    style: Cockpit.mono(
                      size: 9.5,
                      color:
                          online == services.length ? Cockpit.ok : Cockpit.warn,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '展开 ⌃',
                    style: Cockpit.mono(size: 9.5, color: Cockpit.cyan),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: services.length,
              separatorBuilder: (context, index) => const SizedBox(width: 7),
              itemBuilder: (context, index) => _ServiceChip(
                service: services[index],
                onTap: () => onServiceTap(services[index]),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: latest == null ? onExpand : () => onEventTap(latest),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.centerLeft,
                child: latest == null
                    ? Text(
                        '待命中 · 对话、守护、指令和后台任务都会在这里留下痕迹',
                        style: Cockpit.mono(
                          size: 9.5,
                          weight: FontWeight.w600,
                          color: Cockpit.inkDim,
                        ),
                      )
                    : _EventLine(event: latest, dense: true),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceChip extends StatelessWidget {
  const _ServiceChip({required this.service, required this.onTap});

  final CockpitService service;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = toneColor(service.tone);
    final hue = Cockpit.source[service.serviceId] ?? Cockpit.cyan;
    return GestureDetector(
      onTap: onTap,
      child: CockpitSlab(
        accent: color,
        notch: 7,
        borderOpacity: service.online ? 0.35 : 0.6,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              service.glyph,
              style: TextStyle(fontSize: 14, height: 1, color: hue),
            ),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(service.name, style: Cockpit.mono(size: 10)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    CockpitLed(color: color, size: 5),
                    const SizedBox(width: 4),
                    Text(
                      service.checked && service.online
                          ? formatLatency(service.latencyMs)
                          : service.stateLabel,
                      style: Cockpit.mono(
                        size: 8.5,
                        weight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EventLine extends StatelessWidget {
  const _EventLine({required this.event, this.dense = false});

  final CockpitEvent event;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final hue = Cockpit.source[event.source] ?? Cockpit.inkDim;
    final tone = switch (eventTone(event.severity, event.outcome)) {
      PulseTone.bad => Cockpit.bad,
      PulseTone.warn => Cockpit.warn,
      PulseTone.normal => Cockpit.ink,
    };
    return Row(
      children: [
        Text(
          formatClock(event.ts),
          style: Cockpit.mono(
            size: 9.5,
            weight: FontWeight.w600,
            color: Cockpit.inkDim,
          ),
        ),
        const SizedBox(width: 7),
        if (event.origin == 'mock')
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                border:
                    Border.all(color: Cockpit.yellow.withValues(alpha: 0.5)),
              ),
              child: Text(
                'MOCK',
                style: Cockpit.mono(size: 7.5, color: Cockpit.yellow),
              ),
            ),
          ),
        Text(
          event.source.toUpperCase(),
          style: Cockpit.mono(size: 9, color: hue),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            event.summary,
            maxLines: dense ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: Cockpit.sans(
              size: 11.5,
              weight: FontWeight.w600,
              color: tone,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

/// The deck, opened: activity routes, the event log and the substrate, as three
/// tabs. A sheet rather than a drawer because on a phone the map must stay
/// visible behind it — this cockpit is one screen, not a stack of pages.
class CockpitDeckSheet extends StatefulWidget {
  const CockpitDeckSheet({
    super.key,
    required this.snapshot,
    required this.scopeName,
    required this.initialTab,
    required this.controller,
    required this.onActivityTap,
    required this.onEventTap,
    required this.onServiceTap,
  });

  final CockpitSnapshot snapshot;

  /// The focused companion, when there is one. Scope is stated, never implied
  /// by a shorter list.
  final String scopeName;
  final int initialTab;

  /// The sheet's own scroll controller. Handing it to the visible list is what
  /// lets a drag on the content resize the sheet instead of fighting it.
  final ScrollController controller;
  final void Function(CockpitActivity activity) onActivityTap;
  final void Function(CockpitEvent event) onEventTap;
  final void Function(CockpitService service) onServiceTap;

  @override
  State<CockpitDeckSheet> createState() => _CockpitDeckSheetState();
}

class _CockpitDeckSheetState extends State<CockpitDeckSheet> {
  late int _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final tabs = <String>[
      '活动 ${snapshot.activities.length}',
      '事件 ${snapshot.events.length}',
      '底座 ${snapshot.services.length}',
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF07030F).withValues(alpha: 0.97),
        border: Border(top: BorderSide(color: Cockpit.hairStrong)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Container(
              width: 46,
              height: 3,
              margin: const EdgeInsets.symmetric(vertical: 9),
              color: Cockpit.inkDim.withValues(alpha: 0.5),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  for (var index = 0; index < tabs.length; index += 1)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () => setState(() => _tab = index),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: _tab == index
                                  ? Cockpit.cyan
                                  : Cockpit.cyan.withValues(alpha: 0.2),
                            ),
                            color: _tab == index
                                ? Cockpit.cyan.withValues(alpha: 0.12)
                                : null,
                          ),
                          child: Text(
                            tabs[index],
                            style: Cockpit.mono(
                              size: 10,
                              color:
                                  _tab == index ? Cockpit.cyan : Cockpit.inkDim,
                            ),
                          ),
                        ),
                      ),
                    ),
                  const Spacer(),
                  if (widget.scopeName.isNotEmpty)
                    Text(
                      '聚焦：${widget.scopeName}',
                      style: Cockpit.mono(size: 9.5, color: Cockpit.cyan),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: switch (_tab) {
                0 => _ActivityList(
                    activities: snapshot.activities,
                    companionNames: _companionNames(snapshot),
                    controller: widget.controller,
                    onTap: widget.onActivityTap,
                  ),
                1 => _EventList(
                    events: snapshot.events,
                    controller: widget.controller,
                    onTap: widget.onEventTap,
                  ),
                _ => _ServiceList(
                    services: snapshot.services,
                    degraded: snapshot.degradedSources,
                    controller: widget.controller,
                    onTap: widget.onServiceTap,
                  ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

Map<String, String> _companionNames(CockpitSnapshot snapshot) =>
    <String, String>{
      for (final companion in snapshot.companions)
        companion.companionId: companion.displayName,
    };

class _ActivityList extends StatelessWidget {
  const _ActivityList({
    required this.activities,
    required this.companionNames,
    required this.controller,
    required this.onTap,
  });

  final List<CockpitActivity> activities;
  final Map<String, String> companionNames;
  final ScrollController controller;
  final void Function(CockpitActivity activity) onTap;

  @override
  Widget build(BuildContext context) {
    if (activities.isEmpty) {
      return const _Empty(
        text: '待命中 · 对话、守护、指令和后台任务都会在这里形成各自独立的链路',
      );
    }
    return ListView.separated(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      itemCount: activities.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final activity = activities[index];
        final live = isActiveActivity(activity);
        final tone = live
            ? Cockpit.cyan
            : toneColor(
                activity.outcome == 'failure'
                    ? CockpitTone.bad
                    : activity.outcome == 'denied'
                        ? CockpitTone.warn
                        : CockpitTone.ok,
              );
        return GestureDetector(
          onTap: () => onTap(activity),
          child: CockpitSlab(
            accent: tone,
            padding: const EdgeInsets.all(11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: tone.withValues(alpha: 0.14),
                      ),
                      child: Text(
                        activityKindLabel(activity.kind),
                        style: Cockpit.mono(size: 9, color: tone),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        companionNames[activity.companionId] ??
                            (activity.companionId.isEmpty
                                ? '主人'
                                : compactId(activity.companionId)),
                        style: Cockpit.sans(size: 12.5),
                      ),
                    ),
                    Row(
                      children: [
                        CockpitLed(color: tone, size: 6),
                        const SizedBox(width: 5),
                        Text(
                          activityStatusLabel(activity.status),
                          style: Cockpit.mono(size: 9.5, color: tone),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  activity.summary,
                  style: Cockpit.sans(
                    size: 11.5,
                    weight: FontWeight.w500,
                    color: Cockpit.ink,
                    height: 1.35,
                  ),
                ),
                if (activity.route.isNotEmpty) ...[
                  const SizedBox(height: 9),
                  _RouteStrip(activity: activity),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One activity's route as a strip of hops, with the current one lit. The same
/// wavefront the constellation draws, said in words.
class _RouteStrip extends StatelessWidget {
  const _RouteStrip({required this.activity});

  final CockpitActivity activity;

  @override
  Widget build(BuildContext context) {
    final current = currentActivityHop(activity);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var index = 0; index < activity.route.length; index += 1) ...[
            if (index > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Text(
                  '→',
                  style: Cockpit.mono(size: 10, color: Cockpit.inkDim),
                ),
              ),
            _HopChip(
              hop: activity.route[index],
              current: current?.hopId == activity.route[index].hopId,
            ),
          ],
        ],
      ),
    );
  }
}

class _HopChip extends StatelessWidget {
  const _HopChip({required this.hop, required this.current});

  final CockpitHop hop;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final tone = toneColor(statusTone(hop.status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(
          color: current ? Cockpit.cyan : tone.withValues(alpha: 0.4),
        ),
        color: current ? Cockpit.cyan.withValues(alpha: 0.1) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CockpitLed(color: current ? Cockpit.cyan : tone, size: 5),
          const SizedBox(width: 5),
          Text(hop.label, style: Cockpit.mono(size: 9.5)),
          if (hop.latencyMs != null) ...[
            const SizedBox(width: 5),
            Text(
              formatLatency(hop.latencyMs),
              style: Cockpit.mono(size: 9, color: Cockpit.inkDim),
            ),
          ],
        ],
      ),
    );
  }
}

class _EventList extends StatelessWidget {
  const _EventList({
    required this.events,
    required this.controller,
    required this.onTap,
  });

  final List<CockpitEvent> events;
  final ScrollController controller;
  final void Function(CockpitEvent event) onTap;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) return const _Empty(text: '暂无事件');
    return ListView.separated(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      itemCount: events.length,
      separatorBuilder: (context, index) => Divider(
        height: 1,
        color: Cockpit.hair,
      ),
      itemBuilder: (context, index) => GestureDetector(
        onTap: () => onTap(events[index]),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          color: Colors.transparent,
          child: _EventLine(event: events[index]),
        ),
      ),
    );
  }
}

class _ServiceList extends StatelessWidget {
  const _ServiceList({
    required this.services,
    required this.degraded,
    required this.controller,
    required this.onTap,
  });

  final List<CockpitService> services;
  final List<String> degraded;
  final ScrollController controller;
  final void Function(CockpitService service) onTap;

  @override
  Widget build(BuildContext context) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [
          for (final tier in ServiceTier.values) ...[
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 7),
              child: Text(
                switch (tier) {
                  ServiceTier.service => '子项目服务',
                  ServiceTier.middleware => '共享基础设施',
                  ServiceTier.external => '外挂扩展（非核心链路）',
                },
                style: Cockpit.mono(size: 9.5, color: Cockpit.inkDim),
              ),
            ),
            for (final service in services.where((item) => item.tier == tier))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: GestureDetector(
                  onTap: () => onTap(service),
                  child: CockpitSlab(
                    accent: toneColor(service.tone),
                    padding: const EdgeInsets.all(11),
                    child: Row(
                      children: [
                        Text(
                          service.glyph,
                          style: TextStyle(
                            fontSize: 17,
                            height: 1,
                            color: Cockpit.source[service.serviceId] ??
                                Cockpit.cyan,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(service.name,
                                      style: Cockpit.sans(size: 12.5)),
                                  const SizedBox(width: 6),
                                  Text(
                                    service.mode,
                                    style: Cockpit.mono(
                                      size: 8.5,
                                      color: Cockpit.inkDim,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                service.detail.isEmpty
                                    ? service.code
                                    : service.detail,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Cockpit.mono(
                                  size: 9.5,
                                  weight: FontWeight.w600,
                                  color: Cockpit.inkDim,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Row(
                              children: [
                                CockpitLed(
                                  color: toneColor(service.tone),
                                  size: 6,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  service.stateLabel,
                                  style: Cockpit.mono(
                                    size: 9.5,
                                    color: toneColor(service.tone),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              formatLatency(service.latencyMs),
                              style: Cockpit.mono(
                                size: 9,
                                color: Cockpit.inkDim,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
          if (degraded.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                // Said out loud rather than folded into a healthy-looking whole.
                '这一屏读不到：${degraded.join('、')}。它们的状态是未知，不是正常。',
                style: Cockpit.mono(
                  size: 9.5,
                  weight: FontWeight.w600,
                  color: Cockpit.warn,
                  height: 1.5,
                ),
              ),
            ),
        ],
      );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        alignment: Alignment.topLeft,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
        child: Text(
          text,
          style: Cockpit.mono(
            size: 10,
            weight: FontWeight.w600,
            color: Cockpit.inkDim,
            height: 1.6,
          ),
        ),
      );
}
