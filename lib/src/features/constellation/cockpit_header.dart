import 'package:flutter/material.dart';

import 'cockpit_models.dart';
import 'cockpit_theme.dart';

/// The instrument strip above the map.
///
/// The console spreads six meters across a wall; a phone gets one row that
/// scrolls, because dropping meters to fit would be the quiet kind of downgrade
/// this screen is supposed to avoid. Order is by how often it is looked at, so
/// the two that matter — bodies present, activity — are the two you see without
/// scrolling.
class CockpitHeader extends StatelessWidget {
  const CockpitHeader({
    super.key,
    required this.snapshot,
    required this.clockText,
    required this.onBack,
    required this.onRefresh,
    required this.onOwnerTap,
    this.refreshing = false,
    this.compact = false,
    this.readFailed = false,
  });

  final CockpitSnapshot snapshot;
  final String clockText;
  final VoidCallback onBack;
  final VoidCallback onRefresh;
  final VoidCallback onOwnerTap;
  final bool refreshing;

  /// Sideways the meters move to the rail, so the header keeps one row and gives
  /// the map back the height.
  final bool compact;

  /// The last read failed. The chip must not keep saying ONLINE while the strip
  /// below it says the projection could not be read.
  final bool readFailed;

  @override
  Widget build(BuildContext context) {
    final devices = snapshot.devices;
    final online = devices.where((device) => device.online).length;
    final services = snapshot.services;
    final servicesOnline = services.where((service) => service.online).length;
    final activeJobs = snapshot.jobs
        .where((job) => job.status == 'running' || job.status == 'pending')
        .length;
    final activeActivities = snapshot.activities.where(isActiveActivity).length;

    return Container(
      padding: const EdgeInsets.only(left: 6, right: 10, top: 6, bottom: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Cockpit.cyan.withValues(alpha: 0.16)),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _IconButton(
                glyph: '‹',
                onTap: onBack,
                tooltip: '返回',
                ghost: true,
                glyphSize: 22,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: GestureDetector(
                  onTap: onOwnerTap,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              'EIDOLON 星图',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Cockpit.mono(
                                size: 12.5,
                                weight: FontWeight.w900,
                                color: Colors.white,
                                tracking: 0.1,
                              ),
                            ),
                          ),
                          // Said in the chrome, not only in the event rows: a
                          // staged world must never be able to pass for the
                          // Host's own word. Driven by the reading's own
                          // provenance — printed unconditionally, it did the
                          // opposite, and labelled a real Host as staged.
                          if (snapshot.provenance ==
                              CockpitProvenance.staged) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Cockpit.yellow.withValues(alpha: 0.55),
                                ),
                              ),
                              child: Text(
                                'MOCK',
                                style: Cockpit.mono(
                                  size: 7.5,
                                  color: Cockpit.yellow,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'OWNER · ${snapshot.owner.displayName}'
                        ' · TRACE::${snapshot.traceId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Cockpit.mono(size: 9, color: Cockpit.inkDim),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Bounded rather than flexible: a Flexible here took an equal
              // share of the row and left the stream chip and clock floating in
              // the middle of a landscape header instead of on its right edge.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 112),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _StreamChip(
                        state: readFailed
                            ? StreamState.degraded
                            : snapshot.streamState,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        clockText,
                        style: Cockpit.mono(
                          size: 12,
                          weight: FontWeight.w900,
                          color: Cockpit.cyan,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _IconButton(
                glyph: '↻',
                onTap: onRefresh,
                tooltip: '刷新',
                spinning: refreshing,
              ),
            ],
          ),
          if (compact) const SizedBox.shrink() else const SizedBox(height: 8),
          if (!compact)
            SizedBox(
              height: 38 * chromeScale(context),
              // The meters run off the right edge on purpose — dropping any of
              // them would be the quiet downgrade. The fade says "there is more"
              // instead of leaving a hard cut that reads as a layout mistake.
              child: ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: <Color>[
                    Colors.white,
                    Colors.white,
                    Colors.transparent,
                  ],
                  stops: <double>[0, 0.88, 1],
                ).createShader(bounds),
                blendMode: BlendMode.dstIn,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(left: 2, right: 8),
                  children: [
                    // A meter whose lane did not read shows '—'. A zero is a
                    // measurement; this is the absence of one.
                    _Meter(
                      glyph: '⬡',
                      glyphColor: Cockpit.cyan,
                      value: snapshot.devicesLane.readable ? '$online' : '—',
                      suffix: snapshot.devicesLane.readable
                          ? '/${devices.length}'
                          : null,
                      label: '身体在线',
                      ratio: !snapshot.devicesLane.readable || devices.isEmpty
                          ? null
                          : online / devices.length,
                    ),
                    _Meter(
                      glyph: '⚡',
                      glyphColor: Cockpit.magenta,
                      value: snapshot.activitiesLane.readable
                          ? '$activeActivities'
                          : '—',
                      suffix: snapshot.activitiesLane.readable
                          ? '/${snapshot.activities.length}'
                          : null,
                      label: '活动链路',
                    ),
                    _Meter(
                      glyph: '◉',
                      glyphColor: Cockpit.cyan,
                      value: snapshot.companionsLane.readable
                          ? '${snapshot.companions.length}'
                          : '—',
                      label: '伙伴',
                    ),
                    _Meter(
                      glyph: '◈',
                      glyphColor: Cockpit.yellow,
                      value: snapshot.memoryLane.readable
                          ? '${snapshot.memory.realmsTotal}'
                          : '—',
                      label: '记忆空间',
                    ),
                    _Meter(
                      glyph: '⟐',
                      glyphColor: Cockpit.yellow,
                      value: snapshot.memoryLane.readable
                          ? '${snapshot.memory.projectionPending}'
                          : '—',
                      label: '待同步',
                    ),
                    _Meter(
                      glyph: '✦',
                      glyphColor: Cockpit.purple,
                      value: snapshot.jobsLane.readable ? '$activeJobs' : '—',
                      suffix: snapshot.jobsLane.readable
                          ? '/${snapshot.jobs.length}'
                          : null,
                      label: '后台任务',
                    ),
                    _ServiceMeter(
                      services: services,
                      online: servicesOnline,
                      readable: snapshot.servicesLane.readable,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StreamChip extends StatelessWidget {
  const _StreamChip({required this.state});

  final StreamState state;

  @override
  Widget build(BuildContext context) {
    final color = toneColor(streamTone(state));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(border: Border.all(color: color)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CockpitLed(color: color, size: 6),
          const SizedBox(width: 5),
          Text(
            streamLabel(state),
            style: Cockpit.mono(size: 9, color: color, tracking: 0.08),
          ),
        ],
      ),
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter({
    required this.glyph,
    required this.glyphColor,
    required this.value,
    required this.label,
    this.suffix,
    this.ratio,
  });

  final String glyph;
  final Color glyphColor;
  final String value;
  final String label;
  final String? suffix;
  final double? ratio;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11),
    decoration: BoxDecoration(
      border: Border(
        left: BorderSide(color: Cockpit.cyan.withValues(alpha: 0.14)),
      ),
    ),
    child: Row(
      children: [
        Text(
          glyph,
          style: TextStyle(
            fontSize: 18,
            height: 1,
            color: glyphColor,
            shadows: <Shadow>[
              Shadow(color: glyphColor.withValues(alpha: 0.7), blurRadius: 10),
            ],
          ),
        ),
        const SizedBox(width: 7),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: Cockpit.mono(size: 18, weight: FontWeight.w900),
                ),
                if (suffix case final tail?)
                  Text(
                    tail,
                    style: Cockpit.mono(size: 11, color: Cockpit.inkDim),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            if (ratio case final fraction?) ...[
              SizedBox(
                width: 44,
                height: 3,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Cockpit.cyan.withValues(alpha: 0.14),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fraction.clamp(0.0, 1.0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Cockpit.cyan,
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Cockpit.cyan.withValues(alpha: 0.7),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
            ],
            Text(
              label,
              style: Cockpit.mono(
                size: 9,
                weight: FontWeight.w600,
                color: Cockpit.inkDim,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _ServiceMeter extends StatelessWidget {
  const _ServiceMeter({
    required this.services,
    required this.online,
    required this.readable,
  });

  final List<CockpitService> services;
  final int online;
  final bool readable;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11),
    decoration: BoxDecoration(
      border: Border(
        left: BorderSide(color: Cockpit.cyan.withValues(alpha: 0.14)),
      ),
    ),
    child: Row(
      children: [
        Text(
          '▦',
          style: const TextStyle(fontSize: 18, height: 1, color: Cockpit.ink),
        ),
        const SizedBox(width: 7),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (final service in services)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: CockpitLed(color: toneColor(service.tone), size: 7),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              readable ? '底座 $online/${services.length}' : '底座 —',
              style: Cockpit.mono(
                size: 9,
                weight: FontWeight.w600,
                color: Cockpit.inkDim,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.glyph,
    required this.onTap,
    required this.tooltip,
    this.ghost = false,
    this.spinning = false,
    this.glyphSize = 15,
  });

  final String glyph;
  final VoidCallback onTap;
  final String tooltip;
  final bool ghost;
  final bool spinning;
  final double glyphSize;

  @override
  Widget build(BuildContext context) {
    final color = ghost ? Cockpit.inkDim : Cockpit.cyan;
    final label = Text(
      glyph,
      style: TextStyle(fontSize: glyphSize, height: 1, color: color),
    );
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: ghost ? 0.4 : 1)),
            color: ghost ? null : Cockpit.cyan.withValues(alpha: 0.08),
          ),
          child: spinning
              ? SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                )
              : label,
        ),
      ),
    );
  }
}
