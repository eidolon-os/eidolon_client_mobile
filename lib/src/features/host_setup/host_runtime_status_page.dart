import 'dart:async';

import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import '../setup/host_registry.dart';
import 'host_product_session.dart';

/// One current snapshot. No history, persistence, or user interval preference.
const hostMonitorRefreshInterval = Duration(seconds: 10);

class HostRuntimeStatusPage extends StatefulWidget {
  const HostRuntimeStatusPage({
    super.key,
    required this.host,
    required this.connection,
    required this.readMonitor,
  });

  final ManagedHost host;
  final HostProductConnection connection;
  final Future<HostMonitorWire> Function() readMonitor;

  @override
  State<HostRuntimeStatusPage> createState() => _HostRuntimeStatusPageState();
}

class _HostRuntimeStatusPageState extends State<HostRuntimeStatusPage>
    with WidgetsBindingObserver {
  HostMonitorWire? _snapshot;
  String? _error;
  Timer? _timer;
  bool _reading = false;
  bool _visible = false;
  bool _foreground = true;
  bool _readOnReturn = false;
  bool _sortByMemory = false;

  bool get _active => mounted && _visible && _foreground;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = ModalRoute.isCurrentOf(context) ?? true;
    if (visible != _visible) {
      _visible = visible;
      _syncPolling();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncPolling();
  }

  void _syncPolling() {
    _timer?.cancel();
    if (!_active) {
      _readOnReturn = true;
      return;
    }
    if (!_reading) {
      _readOnReturn = false;
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (!_active || _reading) return;
    _timer?.cancel();
    setState(() => _reading = true);
    try {
      final snapshot = await widget.readMonitor();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = switch (error) {
          ManagementRequestException(statusCode: 404) => '这台主机尚未提供监控接口，请更新主机软件',
          ManagementRequestException(statusCode: 401 || 403) =>
            '主机认证已失效，请返回重新连接',
          FormatException() => '主机返回的监控数据无法读取',
          _ => '暂时无法读取主机，请检查连接后重试',
        };
      });
    } finally {
      if (mounted) {
        setState(() => _reading = false);
        if (_active) {
          if (_readOnReturn) {
            _readOnReturn = false;
            unawaited(_refresh());
          } else {
            _timer = Timer(hostMonitorRefreshInterval, _refresh);
          }
        }
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final services = [...?snapshot?.services];
    services.sort((a, b) {
      final av = _sortByMemory ? a.memoryBytes : a.cpuPercent;
      final bv = _sortByMemory ? b.memoryBytes : b.cpuPercent;
      final compared = (bv ?? -1).compareTo(av ?? -1);
      return compared == 0 ? a.serviceId.compareTo(b.serviceId) : compared;
    });
    return Scaffold(
      key: const Key('host-runtime-status-page'),
      appBar: AppBar(title: const Text('主机监控'), actions: [
        IconButton(
          key: const Key('host-runtime-status-refresh'),
          onPressed: _reading ? null : _refresh,
          icon: const Icon(Icons.refresh),
          tooltip: '刷新',
        ),
      ]),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          key: const PageStorageKey('host-monitor-scroll'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          children: [
            Text(widget.host.readableName,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
                '${snapshot?.hostname ?? 'Host'} · ${widget.connection.endpoint.ipAddress}'),
            const SizedBox(height: 8),
            Wrap(spacing: 16, runSpacing: 4, children: [
              Text(_error != null
                  ? '读取失败'
                  : snapshot == null
                      ? '正在读取'
                      : '已获取主机快照'),
              if (snapshot != null)
                Text('运行 ${_duration(snapshot.uptimeSeconds)}'),
              Text('每 ${hostMonitorRefreshInterval.inSeconds} 秒刷新'),
            ]),
            if (snapshot != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    '${_error == null ? '最后更新' : '数据已过期 · 最后更新'} ${_time(snapshot.observedAt)}',
                    key: const Key('host-monitor-timestamp'),
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            const SizedBox(height: 12),
            // Fixed height prevents a poll from moving everything beneath it.
            SizedBox(
                height: 3,
                child: _reading ? const LinearProgressIndicator() : null),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_error!,
                    key: const Key('host-monitor-error'),
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 12),
            if (snapshot == null) ...[
              _Panel(
                  title: 'CPU / NPU',
                  child: Text(_reading ? '正在读取型号与逐核占用…' : '暂无监控数据')),
              const SizedBox(height: 12),
              const _Panel(title: '服务与进程', child: Text('等待主机返回当前快照')),
            ] else ...[
              LayoutBuilder(builder: (context, constraints) {
                final cpu = _ProcessorPanel(label: 'CPU', device: snapshot.cpu);
                final npu = Column(children: [
                  if ((snapshot.npus ?? []).isEmpty)
                    _Panel(
                        title: 'NPU',
                        child: Text(
                            snapshot.npuUnavailableReason ?? '未提供 NPU 数据')),
                  for (final device in snapshot.npus ?? <MonitorProcessor>[])
                    Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _ProcessorPanel(label: 'NPU', device: device)),
                ]);
                if (constraints.maxWidth < 680) {
                  return Column(
                      children: [cpu, const SizedBox(height: 12), npu]);
                }
                return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 3, child: cpu),
                      const SizedBox(width: 14),
                      Expanded(flex: 2, child: npu),
                    ]);
              }),
              const SizedBox(height: 12),
              _CapacityPanel(
                  title: '内存',
                  total: snapshot.memory.totalBytes,
                  available: snapshot.memory.availableBytes,
                  reason: snapshot.memory.unavailableReason),
              for (final disk in snapshot.disks ?? <MonitorDisk>[]) ...[
                const SizedBox(height: 12),
                _CapacityPanel(
                    title: '磁盘 · ${disk.path}',
                    total: disk.totalBytes,
                    available: disk.availableBytes,
                    reason: disk.unavailableReason),
              ],
              const SizedBox(height: 20),
              Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Eidolon OS 服务与进程',
                        style: Theme.of(context).textTheme.titleMedium),
                    DropdownButton<bool>(
                      value: _sortByMemory,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: false, child: Text('按 CPU 排序')),
                        DropdownMenuItem(value: true, child: Text('按内存排序'))
                      ],
                      onChanged: (value) =>
                          setState(() => _sortByMemory = value ?? false),
                    ),
                  ]),
              const Text('CPU 以整机满载为 100% · 展开查看运行路径与启动信息'),
              const SizedBox(height: 10),
              if (snapshot.servicesUnavailableReason != null)
                Text(snapshot.servicesUnavailableReason!),
              if (services.isEmpty &&
                  snapshot.servicesUnavailableReason == null)
                const Text('主机未报告服务'),
              for (final service in services)
                _ServiceTile(
                    key: ValueKey(service.serviceId), service: service),
            ],
          ],
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(title,
                            style: Theme.of(context).textTheme.titleMedium),
                        if (trailing != null) trailing!,
                      ]),
                  const SizedBox(height: 12),
                  child,
                ])),
      );
}

class _ProcessorPanel extends StatelessWidget {
  const _ProcessorPanel({required this.label, required this.device});
  final String label;
  final MonitorProcessor device;
  @override
  Widget build(BuildContext context) => _Panel(
        title: '$label · ${device.model ?? '型号未提供'}',
        trailing: Text(_percent(device.usagePercent),
            style: Theme.of(context).textTheme.headlineSmall),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${device.deviceId} · ${device.cores?.length ?? 0} 个已报告核心'),
          if (device.temperatureCelsius != null)
            Text('${device.temperatureCelsius!.toStringAsFixed(1)} °C'),
          if (device.unavailableReason != null)
            Text(device.unavailableReason!,
                style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, box) {
            final twoColumns = label == 'CPU' && box.maxWidth >= 360;
            final width = twoColumns ? (box.maxWidth - 16) / 2 : box.maxWidth;
            return Wrap(spacing: 16, runSpacing: 14, children: [
              for (final core in device.cores ?? <MonitorCore>[])
                SizedBox(
                    width: width,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(child: Text('$label ${core.coreId}')),
                            Text(_percent(core.usagePercent))
                          ]),
                          Text(
                              [
                                core.model ?? '核心型号未提供',
                                if (core.frequencyMhz != null)
                                  '${core.frequencyMhz!.toStringAsFixed(0)} MHz'
                              ].join(' · '),
                              style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(height: 5),
                          _Meter(value: core.usagePercent),
                          if (core.usagePercent == null)
                            Text(core.unavailableReason ?? '占用未提供',
                                style: Theme.of(context).textTheme.bodySmall),
                        ])),
            ]);
          }),
          const SizedBox(height: 10),
          Text('每核满载为 100%', style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}

class _Meter extends StatelessWidget {
  const _Meter({this.value});
  final double? value;
  @override
  Widget build(BuildContext context) => LinearProgressIndicator(
        value:
            value == null || !value!.isFinite ? 0 : (value! / 100).clamp(0, 1),
        minHeight: 5,
        borderRadius: BorderRadius.circular(3),
        color: value == null ? Colors.transparent : null,
      );
}

class _CapacityPanel extends StatelessWidget {
  const _CapacityPanel(
      {required this.title, this.total, this.available, this.reason});
  final String title;
  final int? total;
  final int? available;
  final String? reason;
  @override
  Widget build(BuildContext context) {
    final used = total == null || available == null
        ? null
        : (total! - available!).clamp(0, total!);
    final percent = total == null || total! <= 0 || used == null
        ? null
        : used * 100 / total!;
    return _Panel(
        title: title,
        trailing: Text(_percent(percent),
            style: Theme.of(context).textTheme.titleLarge),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Meter(value: percent),
          const SizedBox(height: 10),
          Text(used == null
              ? reason ?? '数据未提供'
              : '已用 ${_bytes(used)} / ${_bytes(total)} · 可用 ${_bytes(available)}'),
        ]));
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({super.key, required this.service});
  final MonitorService service;
  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ExpansionTile(
          key: PageStorageKey('monitor-service-${service.serviceId}'),
          maintainState: true,
          title: Text(service.serviceId),
          subtitle:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(service.state),
            Wrap(spacing: 16, runSpacing: 3, children: [
              Text('CPU ${_percent(service.cpuPercent)}'),
              Text('内存 ${_bytes(service.memoryBytes)}'),
              Text('${service.processes?.length ?? 0} 个进程'),
            ]),
          ]),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Field('服务单元', service.unit),
            _Field('服务配置路径', service.configurationPath),
            _Field('工作目录', service.workingDirectory),
            _Field('运行用户', service.user),
            _Field('主 PID', service.mainPid?.toString()),
            _Field('最近退出码', service.exitCode?.toString()),
            Text('服务内存口径：${service.memoryKind ?? 'cgroup'}',
                style: Theme.of(context).textTheme.bodySmall),
            if (service.unavailableReason != null)
              Text(service.unavailableReason!),
            const Divider(),
            if ((service.processes ?? []).isEmpty) const Text('未发现可读取的运行进程'),
            for (final process in service.processes ?? <MonitorProcess>[])
              ExpansionTile(
                key: PageStorageKey(
                    'monitor-process-${service.serviceId}-${process.pid}-${process.startedAt}'),
                tilePadding: EdgeInsets.zero,
                title: Text('${process.name} · PID ${process.pid}'),
                subtitle: Text(
                    'CPU ${_percent(process.cpuPercent)} · RSS ${_bytes(process.rssBytes)}'),
                expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Field(
                      '父 PID / 状态', '${process.parentPid} / ${process.state}'),
                  _Field('运行用户', process.user),
                  _Field('可执行文件', process.executable),
                  _Field('运行入口文件', process.sourcePath,
                      fallback: process.entryModule == null
                          ? '无法确定源码位置（可能为编译程序）'
                          : '以模块启动，未推断源码路径'),
                  if (process.entryModule != null)
                    _Field('入口模块', process.entryModule),
                  _Field('工作目录', process.workingDirectory),
                  _Field('启动命令（已脱敏）', process.command),
                  _Field(
                      '启动时间',
                      process.startedAt == null
                          ? null
                          : _time(process.startedAt!)),
                  _Field('运行时长', _duration(process.uptimeSeconds)),
                  if (process.unavailableReason != null)
                    Text(process.unavailableReason!),
                  const SizedBox(height: 12),
                ],
              ),
          ],
        ),
      );
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.fallback = '未提供'});
  final String label;
  final String? value;
  final String fallback;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          SelectableText(value == null || value!.isEmpty ? fallback : value!,
            key: PageStorageKey('monitor-field-$label')),
        ]),
      );
}

String _percent(double? value) =>
    value == null || !value.isFinite ? '—' : '${value.toStringAsFixed(1)}%';
String _bytes(int? value) {
  if (value == null) return '—';
  if (value >= 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  }
  return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

String _duration(double? seconds) {
  if (seconds == null || !seconds.isFinite) return '未提供';
  final d = Duration(seconds: seconds.toInt());
  return '${d.inDays}天 ${d.inHours % 24}小时 ${d.inMinutes % 60}分';
}

String _time(String text) {
  final time = DateTime.tryParse(text)?.toLocal();
  if (time == null) return '时间未提供';
  return time.toString().split('.').first;
}
