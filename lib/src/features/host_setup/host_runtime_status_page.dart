import 'dart:async';

import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import '../device_management/mounted_device_models.dart';
import '../setup/host_registry.dart';
import 'activity_models.dart';
import 'host_models.dart';
import 'host_product_session.dart';
import 'host_runtime_verdict.dart';
import 'host_service_models.dart';
import 'host_vitals_models.dart';

typedef HostServiceLister = Future<HostServiceInventory> Function();
typedef HostServiceChanger = Future<HostServiceChange> Function({
  required String serviceId,
  required String operation,
  required int expectedRevision,
});

/// 主机运行状态 — this machine, in words.
///
/// One page where there were three. 运行驾驶舱, 主机动态 and 查看系统状态 read
/// overlapping sources (services three times, activity twice) and each drew
/// everything it could read at full size, always — so "is anything wrong" was a
/// question you answered by reading three screens and noticing an absence.
///
/// It is not those three stacked. The order here is the reader's question, not
/// the source list:
///
/// 1. **一句判词** — computed from the same reads the rows below are drawn from,
///    so the top of the screen cannot disagree with the middle of it. On a
///    healthy Host that is the whole answer;
/// 2. **异常在前, 正常压成一行.** 底座 8/13 is one line until you open it; a
///    service that is down is already above, with its restart *on its own row*
///    rather than in a separate services card;
/// 3. **一条时间线.** The activity feed already carries devices arriving, being
///    accepted and being removed — so the device list and the device history
///    stop being two screens;
/// 4. **出问题时要引用的**, collapsed. Host id, fingerprint, epoch: things you
///    copy into a bug report, not things you read;
/// 5. **危险动作最后**.
///
/// Each source is read exactly once, here, so no two parts of the screen can
/// describe the same fact differently. What belongs to the *domain* rather than
/// to the machine — who the Owner is, which Eidolons exist, what is happening
/// for them — is not here at all: that is 驾驶舱. §3.2 of
/// `docs/constellation-cockpit.md` argued that boundary before this page
/// existed; the old 运行驾驶舱 read `home` and blurred it.
class HostRuntimeStatusPage extends StatefulWidget {
  const HostRuntimeStatusPage({
    super.key,
    required this.host,
    required this.connection,
    this.readVitals,
    this.listServices,
    this.changeService,
    this.loadActivity,
    this.listControllers,
    this.devices,
    this.devicesError,
    this.revokeRuntimeSessions,
    this.sessionRevokeHold,
  });

  final ManagedHost host;
  final HostProductConnection connection;

  /// Null on a Host too old to be asked. Optional throughout for the same
  /// reason: one capability this Host predates must not cost the whole page.
  final Future<HostVitals> Function()? readVitals;
  final HostServiceLister? listServices;
  final HostServiceChanger? changeService;
  final Future<HostActivity> Function()? loadActivity;
  final Future<List<ControllerView>> Function()? listControllers;

  /// What the Host already said about devices, rather than asking again: this
  /// page is a place to look, not a second opinion.
  final MountedDeviceInventory? devices;
  final String? devicesError;

  /// End every runtime session, so every device has to sign in again. On this
  /// page rather than the devices one because it is not aimed at a device: it
  /// ends *all* of them, and the reason someone wants it is that one is out of
  /// their hands.
  final Future<RevokedSessionsView> Function()? revokeRuntimeSessions;

  /// Why this Host is not offering that. The control stays and says so: hiding
  /// it leaves somebody looking, and offering it promises what the Host cannot
  /// do.
  final String? sessionRevokeHold;

  @override
  State<HostRuntimeStatusPage> createState() => _HostRuntimeStatusPageState();
}

class _HostRuntimeStatusPageState extends State<HostRuntimeStatusPage> {
  HostVitals? _vitals;
  String? _vitalsError;
  List<HostService>? _services;
  String? _servicesError;
  HostActivity? _activity;
  String? _activityError;
  List<ControllerView>? _controllers;
  String? _controllersError;
  String? _busyServiceId;
  var _reading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_readAll());
  }

  /// One pass, every source once. Concurrent because they are independent, and
  /// each failure lands in its own field: a Host that cannot report its disk
  /// still says which services are up.
  Future<void> _readAll() async {
    setState(() => _reading = true);
    await Future.wait<void>([
      _read(widget.readVitals, (value) => _vitals = value,
          (e) => _vitalsError = e),
      _read(widget.listServices, (value) => _services = value?.services,
          (e) => _servicesError = e),
      _read(widget.loadActivity, (value) => _activity = value,
          (e) => _activityError = e),
      _read(widget.listControllers, (value) => _controllers = value,
          (e) => _controllersError = e),
    ]);
    if (mounted) setState(() => _reading = false);
  }

  Future<void> _read<T>(
    Future<T> Function()? source,
    void Function(T? value) keep,
    void Function(String? error) fail,
  ) async {
    if (source == null) return;
    fail(null);
    try {
      final value = await source();
      if (!mounted) return;
      setState(() => keep(value));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        keep(null);
        fail('$error');
      });
    }
  }

  Future<void> _restart(HostService service) async {
    final changer = widget.changeService;
    if (changer == null) return;
    setState(() {
      _busyServiceId = service.serviceId;
      _servicesError = null;
    });
    try {
      await changer(
        serviceId: service.serviceId,
        operation: 'restart',
        // The revision on screen, so a stale view is rejected rather than
        // applied to something that has since moved.
        expectedRevision: service.revision,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _servicesError = '$error');
    } finally {
      if (mounted) setState(() => _busyServiceId = null);
    }
    // Re-read rather than patch the row: what the Host says now is the answer,
    // and the verdict above is computed from the same read.
    await _read(widget.listServices, (value) => _services = value?.services,
        (e) => _servicesError = e);
  }

  @override
  Widget build(BuildContext context) {
    final verdict = hostVerdict(
      vitals: _vitals,
      vitalsFailure: _vitalsError,
      services:
          _services == null ? null : HostServiceInventory(services: _services!),
      servicesFailure: _servicesError,
      devicesFailure: widget.devicesError,
      activityFailure: _activityError,
      controllersFailure: _controllersError,
    );
    return Scaffold(
      key: const Key('host-runtime-status-page'),
      appBar: AppBar(
        title: const Text('主机运行状态'),
        actions: [
          IconButton(
            key: const Key('host-runtime-status-refresh'),
            onPressed: _reading ? null : _readAll,
            icon: const Icon(Icons.refresh),
            tooltip: '重新读一次',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _Verdict(
            verdict: verdict,
            reading: _reading,
            busyServiceId: _busyServiceId,
            onRestart: widget.changeService == null
                ? null
                : (serviceId) {
                    final service = _services?.firstWhere(
                      (candidate) => candidate.serviceId == serviceId,
                    );
                    if (service != null) unawaited(_restart(service));
                  },
          ),
          const SizedBox(height: 16),
          _StatusHeader(state: widget.connection.overview.state),
          const SizedBox(height: 16),
          _MachineLine(vitals: _vitals, error: _vitalsError, reading: _reading),
          const SizedBox(height: 12),
          _FloorLines(
            services: _services,
            error: _servicesError,
            reading: _reading,
            busyServiceId: _busyServiceId,
            onRestart: widget.changeService == null ? null : _restart,
          ),
          const SizedBox(height: 12),
          _BodyLines(devices: widget.devices, error: widget.devicesError),
          const SizedBox(height: 12),
          _PhoneLines(controllers: _controllers, error: _controllersError),
          const SizedBox(height: 16),
          _Timeline(
              activity: _activity, error: _activityError, reading: _reading),
          const SizedBox(height: 16),
          _ForQuoting(host: widget.host, connection: widget.connection),
          if (widget.revokeRuntimeSessions case final revoke?) ...[
            const SizedBox(height: 16),
            _SignOutDevicesCard(revoke: revoke, hold: widget.sessionRevokeHold),
          ],
          const SizedBox(height: 12),
          Text(
            '这里是这台机器的状态与它能做的操作。谁是主人、有哪些 Eidolon、'
            '正在为它们发生什么，在「驾驶舱」。发布、激活和回滚仍由 Ops 在工作站执行。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// The one line, and the things that keep it from being 正常.
///
/// Nothing is claimed before the first read finishes: "一切正常" from a page
/// that has not asked yet is the most expensive sentence on this screen.
class _Verdict extends StatelessWidget {
  const _Verdict({
    required this.verdict,
    required this.reading,
    required this.busyServiceId,
    required this.onRestart,
  });

  final HostVerdict verdict;
  final bool reading;
  final String? busyServiceId;
  final void Function(String serviceId)? onRestart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (icon, tint) = switch (verdict.level) {
      HostConcernLevel.act => (Icons.error, colors.error),
      HostConcernLevel.watch => (Icons.warning_amber, colors.tertiary),
      HostConcernLevel.unknown => (Icons.help_outline, colors.outline),
      HostConcernLevel.none => (Icons.check_circle, colors.primary),
    };
    return Card(
      key: const Key('host-runtime-verdict'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (reading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(icon, color: tint),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    reading ? '正在读这台主机' : verdict.headline,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (!reading)
              for (final concern in verdict.concerns) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(concern.what, style: theme.textTheme.bodyMedium),
                          Text(
                            concern.why,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // The action sits with the thing it acts on, which is why
                    // there is no separate services card any more.
                    if (concern.serviceId case final serviceId?)
                      if (onRestart case final restart?)
                        busyServiceId == serviceId
                            ? const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 12),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : TextButton(
                                key: Key('restart-$serviceId'),
                                onPressed: () => restart(serviceId),
                                child: const Text('重启'),
                              ),
                  ],
                ),
              ],
          ],
        ),
      ),
    );
  }
}

/// The machine, in one row. Disk, memory, load, temperature.
///
/// The judgement of what counts as too little was already made Host-side; this
/// shows the verdict rather than re-deciding it, so the two cannot drift apart.
class _MachineLine extends StatelessWidget {
  const _MachineLine(
      {required this.vitals, required this.error, required this.reading});

  final HostVitals? vitals;
  final String? error;
  final bool reading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (error != null) {
      // Why is in the verdict above, once. Repeating it here would put the same
      // sentence on the screen twice.
      return const _Line(
        key: Key('host-machine-line'),
        label: '机器',
        value: '读不到',
      );
    }
    final reading0 = vitals;
    if (reading0 == null) {
      return _Line(
        label: '机器',
        value: reading ? '读取中' : '这台主机没有报告读数',
        key: const Key('host-machine-line'),
      );
    }
    return _Line(
      key: const Key('host-machine-line'),
      label: '机器',
      value: reading0.vitals
          .map((vital) => vital.isUnavailable
              ? '${vital.name} 读不到'
              : '${vital.name} ${vital.reading}')
          .join(' · '),
      detail: reading0.observedAt == null
          ? null
          : '读于 ${_dateTime(reading0.observedAt!)}',
      style: theme.textTheme.bodyMedium,
    );
  }
}

/// 底座 N/M in one line, with every service one tap away.
///
/// Collapsed on purpose: anything wrong is already in the verdict above, with
/// its restart. This is for browsing, not for finding out.
class _FloorLines extends StatelessWidget {
  const _FloorLines({
    required this.services,
    required this.error,
    required this.reading,
    required this.busyServiceId,
    required this.onRestart,
  });

  final List<HostService>? services;
  final String? error;
  final bool reading;
  final String? busyServiceId;
  final Future<void> Function(HostService service)? onRestart;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return const _Line(
        key: Key('host-floor-line'),
        label: '底座',
        value: '读不到',
      );
    }
    final rows = services;
    if (rows == null || rows.isEmpty) {
      return _Line(
        key: const Key('host-floor-line'),
        label: '底座',
        value: reading ? '读取中' : '这台主机没有报告任何服务',
      );
    }
    final up = rows
        .where(
            (service) => service.runtimeState == HostServiceRuntimeState.ready)
        .length;
    return Card(
      child: ExpansionTile(
        key: const Key('host-floor-line'),
        title: Row(
          children: [
            const Text('底座'),
            const Spacer(),
            Text('$up/${rows.length}'),
          ],
        ),
        children: [
          for (final service in rows)
            _HostServiceRow(
              service: service,
              busy: busyServiceId == service.serviceId,
              onRestart: onRestart == null ? null : () => onRestart!(service),
            ),
        ],
      ),
    );
  }
}

/// The bodies this Owner has, by name.
class _BodyLines extends StatelessWidget {
  const _BodyLines({required this.devices, required this.error});

  final MountedDeviceInventory? devices;
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return const _Line(
        key: Key('host-bodies-line'),
        label: '设备',
        value: '读不到',
      );
    }
    final inventory = devices;
    if (inventory == null) {
      // Nobody asked, which is not the same as none.
      return const _Line(
        key: Key('host-bodies-line'),
        label: '设备',
        value: '还没有问过',
      );
    }
    if (inventory.devices.isEmpty) {
      return const _Line(
        key: Key('host-bodies-line'),
        label: '设备',
        value: '还没有设备属于这台主机',
      );
    }
    return _Line(
      key: const Key('host-bodies-line'),
      label: '设备',
      value: '${inventory.devices.length} 台',
      detail: inventory.devices.map((device) => device.label).join(' · '),
    );
  }
}

/// Which phones may manage this Host. 本机 is marked, because the one question
/// people ask of this list is whether the phone in their hand is on it.
class _PhoneLines extends StatelessWidget {
  const _PhoneLines({required this.controllers, required this.error});

  final List<ControllerView>? controllers;
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return const _Line(
        key: Key('host-phones-line'),
        label: '管理这台主机的手机',
        value: '读不到',
      );
    }
    final rows = controllers;
    if (rows == null) {
      return const _Line(
        key: Key('host-phones-line'),
        label: '管理这台主机的手机',
        value: '还没有问过',
      );
    }
    return _Line(
      key: const Key('host-phones-line'),
      label: '管理这台主机的手机',
      value: '${rows.length} 台',
      detail: rows
          .map((grant) =>
              '${grant.displayName ?? grant.controllerId}${grant.isYou ? '（本机）' : ''}')
          .join(' · '),
    );
  }
}

/// 最近的改动 — one timeline, in sentences.
///
/// This is where 主机动态 went, and it is named for what it actually holds.
/// §3.2 described that screen as "设备的到来、接受、移除"; its own coverage
/// sentence says otherwise, and so does its vocabulary — companionArrived,
/// answeringChanged, faceChanged, ownerNamed. It is a change log for this Host,
/// not a device history, and calling it 最近发生 invited the reader to expect
/// everything.
///
/// The coverage sentence comes with it verbatim: a list that looks complete and
/// is not is worse than a short one that says what it holds.
class _Timeline extends StatelessWidget {
  const _Timeline(
      {required this.activity, required this.error, required this.reading});

  final HostActivity? activity;
  final String? error;
  final bool reading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _SectionCard(
      title: '最近的改动',
      children: [
        if (error != null) ...[
          Text('读不到，原因在上面那句判词里。', style: theme.textTheme.bodyMedium),
        ] else if (activity case final feed?) ...[
          Text(
            // Carried verbatim from 主机动态. What this list does not know, said
            // out loud rather than implied by a short list.
            '这里记的是这台主机做过的改动——伙伴的来去、谁来回答、换过的脸。'
            '设备是否在线不在其中，这台主机不记那个。',
            key: const Key('host-changes-coverage'),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (feed.moments.isEmpty)
            Text('这台主机还没有留下痕迹。', style: theme.textTheme.bodyMedium)
          else
            for (final moment in collapseMoments(feed.moments).take(12))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(hostMomentSentence(moment)),
              ),
        ] else
          Text(reading ? '读取中' : '这台主机不提供活动记录',
              style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

/// The things you copy into a bug report. Collapsed, because that is what they
/// are for — the three screens this replaces each showed them at full size.
class _ForQuoting extends StatelessWidget {
  const _ForQuoting({required this.host, required this.connection});

  final ManagedHost host;
  final HostProductConnection connection;

  @override
  Widget build(BuildContext context) {
    final state = connection.overview.state;
    return Card(
      child: ExpansionTile(
        key: const Key('host-for-quoting'),
        title: const Text('出问题时要引用的'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _StatusRow(
                    label: '服务', value: connection.endpoint.instanceName),
                _StatusRow(
                    label: 'Host IP', value: connection.endpoint.ipAddress),
                _StatusRow(
                  label: '管理会话',
                  value: '有效至 ${_dateTime(connection.sessionExpiresAt)}',
                ),
                _StatusRow(label: 'Controller', value: connection.controllerId),
                _StatusRow(
                  label: '运行模式',
                  value: connection.overview.mode == BootstrapMode.development
                      ? '开发'
                      : '产品',
                ),
                _StatusRow(label: 'Owner', value: _claimLabel(state.claim)),
                _StatusRow(label: '网络', value: networkLabel(state.network)),
                _StatusRow(label: 'Reset epoch', value: '${state.resetEpoch}'),
                _StatusRow(label: '状态更新时间', value: _dateTime(state.updatedAt)),
                _SelectableStatusRow(label: 'Host ID', value: host.hostId),
                _SelectableStatusRow(
                  label: 'Host fingerprint',
                  value: host.hostFingerprint,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One fact: a label, what it says, and why when that needs saying.
class _Line extends StatelessWidget {
  const _Line({
    super.key,
    required this.label,
    required this.value,
    this.detail,
    this.style,
  });

  final String label;
  final String value;
  final String? detail;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(label, style: theme.textTheme.titleSmall),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    value,
                    style: style ?? theme.textTheme.bodyMedium,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
            if (detail case final text?) ...[
              const SizedBox(height: 4),
              Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 让所有设备重新登录 — the action for a device that is out of someone's hands.
///
/// Confirmed here rather than at the boundary, because whether to ask twice is a
/// question about a screen. What the dialog has to get right is the scope: this
/// ends the sessions devices use to *talk* to an Eidolon, and it does not touch
/// which phones may *manage* this Host. Someone reading "让所有设备重新登录"
/// could reasonably fear it locks them out of this very app, and it does not.
class _SignOutDevicesCard extends StatefulWidget {
  const _SignOutDevicesCard({required this.revoke, this.hold});

  final Future<RevokedSessionsView> Function() revoke;

  /// Non-null holds the button back and says why instead of running it.
  final String? hold;

  @override
  State<_SignOutDevicesCard> createState() => _SignOutDevicesCardState();
}

class _SignOutDevicesCardState extends State<_SignOutDevicesCard> {
  bool _busy = false;
  String? _outcome;

  Future<void> _confirmAndRevoke() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('confirm-sign-out-devices'),
        title: const Text('让所有设备重新登录？'),
        content: const Text(
          '每台设备都要重新取得会话才能再和它说话，它们会自己完成。'
          '正在进行的语音或对话会断开。\n\n'
          '这不会影响任何手机对这台主机的管理权限，也不会解绑设备。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-sign-out-devices-action'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('让它们重新登录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _outcome = null;
    });
    try {
      final revoked = await widget.revoke();
      if (!mounted) return;
      // The instant, not a claim of completeness: a device that is offline right
      // now finds out when it comes back.
      setState(() => _outcome =
          '已在 ${_dateTime(DateTime.tryParse(revoked.revokedAt) ?? DateTime.now())} 让所有设备重新登录');
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _outcome = error is ManagementRequestException &&
                error.statusCode == 503
            // Saying "done" here would leave someone believing a missing phone
            // had been cut off.
            ? '这台主机现在做不了这件事，设备仍然在线'
            : '没能完成：$error',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: '设备会话',
      children: [
        const Text('如果有一台设备不在你手上了，可以让所有设备重新登录。'),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: widget.hold != null
              ? Row(
                  key: const Key('sign-out-devices-held'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.logout, size: 18),
                    const SizedBox(width: 8),
                    const Text('让所有设备重新登录'),
                    const SizedBox(width: 8),
                    Chip(label: Text(widget.hold!)),
                  ],
                )
              : OutlinedButton.icon(
                  key: const Key('sign-out-devices'),
                  onPressed: _busy ? null : _confirmAndRevoke,
                  icon: const Icon(Icons.logout),
                  label: const Text('让所有设备重新登录'),
                ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(key: Key('sign-out-devices-busy')),
          ),
        if (_outcome case final outcome?)
          Padding(
            key: const Key('sign-out-devices-outcome'),
            padding: const EdgeInsets.only(top: 12),
            child: Text(outcome),
          ),
      ],
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.state});

  final HostBootstrapState state;

  @override
  Widget build(BuildContext context) {
    final healthy = state.claim == HostClaimState.claimed &&
        state.network == HostNetworkState.connected;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(
              healthy ? Icons.check_circle : Icons.warning_amber_rounded,
              size: 34,
              color: healthy
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.tertiary,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    healthy ? '主机本地管理正常' : '主机需要关注',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text('网络：${networkLabel(state.network)}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HostServiceRow extends StatelessWidget {
  const _HostServiceRow({
    required this.service,
    required this.busy,
    this.onRestart,
  });

  final HostService service;
  final bool busy;
  final VoidCallback? onRestart;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final healthy = service.runtimeState == HostServiceRuntimeState.ready;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(
            healthy ? Icons.check_circle : Icons.error_outline,
            size: 18,
            color: healthy ? scheme.primary : scheme.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(service.serviceId),
                Text(
                  service.detail ?? hostServiceStateLabel(service.runtimeState),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (onRestart case final restart?)
            TextButton(onPressed: restart, child: const Text('重启')),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      );
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 112, child: Text(label)),
            Expanded(child: Text(value, textAlign: TextAlign.end)),
          ],
        ),
      );
}

class _SelectableStatusRow extends StatelessWidget {
  const _SelectableStatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 4),
            SelectableText(value),
          ],
        ),
      );
}

String networkLabel(HostNetworkState state) => switch (state) {
      HostNetworkState.unconfigured => '未配置',
      HostNetworkState.staging => '正在切换',
      HostNetworkState.connected => '已连接',
      HostNetworkState.degraded => '异常',
      HostNetworkState.rollingBack => '正在恢复',
    };

String _claimLabel(HostClaimState state) => switch (state) {
      HostClaimState.unclaimed => '未认领',
      HostClaimState.claimed => '已认领',
    };

String _dateTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// How the machine itself is doing.
///
/// The Host has already phrased every reading and already decided which ones
/// are worth acting on; this draws that and adds nothing. Deciding here as
/// well would put one judgement in two places, and the day they disagree the
/// screen and the Host would each be telling the truth about a different rule.
