import 'package:flutter/material.dart';

import '../device_management/mounted_device_models.dart';
import 'activity_models.dart';
import '../../generated/management_v1.dart';
import 'host_service_models.dart';
import 'host_vitals_models.dart';
import 'home_models.dart';

/// The sovereign domain of one Host, on one screen.
///
/// The same information model as the Admin console's cockpit — Owner ▸
/// Companion ▸ devices and memory — arranged for a phone rather than for a
/// wall. It is not a port of that screen: a constellation with orbit fields
/// belongs on a large display, and what carries over is the model, not the
/// drawing.
///
/// It shows one thing the console's cockpit cannot: this Host's vitals. The
/// console asks the authorities over HTTP and none of them publishes disk,
/// memory or temperature; the Local API does, because the phone is the thing
/// an Owner has with them when a Host stops answering.
///
/// Every lane is asked for separately, fails separately, and says so in its
/// own place. None of them renders as empty when it could not be read — the
/// distinction between "quiet" and "could not tell" is the whole reason to
/// look at a screen like this, and losing it once cost a day of hunting for a
/// device that had in fact arrived.
///
/// What no authority publishes at all is listed at the bottom by name. A
/// cockpit that silently omits a dial teaches its reader that the dial does
/// not exist.
class RuntimeCockpitPage extends StatefulWidget {
  const RuntimeCockpitPage({
    super.key,
    required this.home,
    required this.loadVitals,
    required this.listServices,
    required this.loadActivity,
    required this.listControllers,
    this.devices,
    this.devicesError,
  });

  /// Owner, Companion, persona and memory realm — already read by the screen
  /// that opened this one. Null means the Workspace is not ready, and there is
  /// no domain to draw.
  /// What is mine, right now. Null means the Host could not say, and this page
  /// draws the lanes it can rather than nothing.
  final HostHome? home;

  final Future<HostVitals> Function() loadVitals;
  final Future<HostServiceInventory> Function() listServices;
  final Future<HostActivity> Function() loadActivity;
  final Future<List<ControllerView>> Function() listControllers;

  /// What the Host already said about this Owner's devices. Null with no error
  /// means nobody has asked yet.
  final MountedDeviceInventory? devices;
  final String? devicesError;

  @override
  State<RuntimeCockpitPage> createState() => _RuntimeCockpitPageState();
}

class _RuntimeCockpitPageState extends State<RuntimeCockpitPage> {
  _Lane<HostVitals> _vitals = const _Lane.loading();
  _Lane<HostServiceInventory> _services = const _Lane.loading();
  _Lane<HostActivity> _activity = const _Lane.loading();
  _Lane<List<ControllerView>> _controllers = const _Lane.loading();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => Future.wait([
        _read(widget.loadVitals, (lane) => _vitals = lane),
        _read(widget.listServices, (lane) => _services = lane),
        _read(widget.loadActivity, (lane) => _activity = lane),
        _read(widget.listControllers, (lane) => _controllers = lane),
      ]);

  /// One lane, asked for on its own so its failure stays its own.
  Future<void> _read<T>(
    Future<T> Function() ask,
    void Function(_Lane<T>) assign,
  ) async {
    if (!mounted) return;
    setState(() => assign(const _Lane.loading()));
    try {
      final value = await ask();
      if (mounted) setState(() => assign(_Lane.value(value)));
    } catch (error) {
      if (mounted) setState(() => assign(_Lane.failed('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final home = widget.home;
    return Scaffold(
      appBar: AppBar(title: const Text('运行驾驶舱')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (home == null)
              const _Unavailable(
                title: '主权域',
                reason: '这台主机还没有建立 Workspace，没有可显示的归属关系',
              )
            else
              _SovereignDomain(
                home: home,
                devices: widget.devices,
                devicesError: widget.devicesError,
              ),
            const SizedBox(height: 16),
            _VitalsSection(
                lane: _vitals,
                onRetry: () => _read(widget.loadVitals, (l) => _vitals = l)),
            const SizedBox(height: 16),
            _ServicesSection(
              lane: _services,
              onRetry: () => _read(widget.listServices, (l) => _services = l),
            ),
            const SizedBox(height: 16),
            _ControllersSection(
              lane: _controllers,
              onRetry: () =>
                  _read(widget.listControllers, (l) => _controllers = l),
            ),
            const SizedBox(height: 16),
            _ActivitySection(
              lane: _activity,
              onRetry: () => _read(widget.loadActivity, (l) => _activity = l),
            ),
            const SizedBox(height: 16),
            const _NotPublished(),
          ],
        ),
      ),
    );
  }
}

/// A lane's three states, kept apart on purpose.
///
/// "Still asking", "asked and it failed" and "asked and there is nothing"
/// are three different things. Collapsing the last two into an empty list is
/// what makes a dashboard lie.
class _Lane<T> {
  const _Lane.loading()
      : value = null,
        error = null,
        loading = true;
  const _Lane.value(this.value)
      : error = null,
        loading = false;
  const _Lane.failed(this.error)
      : value = null,
        loading = false;

  final T? value;
  final String? error;
  final bool loading;
}

/// Owner ▸ Companion ▸ devices and memory: what is whose.
///
/// Drawn as containment rather than as a graph. On a phone the useful question
/// is "what is mine and what is it attached to", and nesting answers it in one
/// glance where a constellation would need panning.
class _SovereignDomain extends StatelessWidget {
  const _SovereignDomain({
    required this.home,
    required this.devices,
    required this.devicesError,
  });

  final HostHome home;
  final MountedDeviceInventory? devices;
  final String? devicesError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The one that answers when nobody was named, which is what this panel is
    // about — the routing setting itself, said as such. It is not "the Eidolon"
    // and not "the running one": the list on the home screen says which are
    // running, and several can be.
    final companion = home.answering;
    final memory = home.memory;
    return Card(
      key: const Key('cockpit-sovereign-domain'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('主权域', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Text(home.ownerDisplayName, style: theme.textTheme.titleLarge),
            Text('这台主机属于的人', style: theme.textTheme.bodySmall),
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    companion?.displayName.isNotEmpty == true
                        ? companion!.displayName
                        : '还没有指定由谁回答',
                    style: theme.textTheme.titleMedium,
                  ),
                  if (companion != null)
                    Text(
                      // What state the Host says it is in, which is what this
                      // panel is about. Which chapter its persona is on is a
                      // fact about the Eidolon rather than about the runtime,
                      // and it lives on the Eidolon's own page — here it only
                      // ever described whichever one happened to answer.
                      _runtimeLine(companion),
                      style: theme.textTheme.bodySmall,
                    ),
                  const SizedBox(height: 12),
                  _MemoryRow(memory: memory),
                  const SizedBox(height: 12),
                  _DevicesRow(
                    devices: devices,
                    devicesError: devicesError,
                    companionId: companion?.companionId,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoryRow extends StatelessWidget {
  const _MemoryRow({required this.memory});

  /// What it remembers, as the Host phrased it. A realm identifier was never an
  /// answer to "does it still remember me"; a count is.
  final String memory;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Icon(Icons.hub_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              memory.isNotEmpty ? memory : '记忆读不到',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      );
}

class _DevicesRow extends StatelessWidget {
  const _DevicesRow({
    required this.devices,
    required this.devicesError,
    required this.companionId,
  });

  final MountedDeviceInventory? devices;
  final String? devicesError;

  /// Null when nobody answers for this Owner yet, which is a real state and
  /// not a reason to hide the device count.
  final String? companionId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (devicesError != null) {
      return _InlineUnavailable(reason: '设备清单读不到：$devicesError');
    }
    final inventory = devices;
    if (inventory == null) {
      // Nobody asked, which is not the same as none. Saying so keeps a screen
      // that was opened early from reading as a Host with no devices.
      return const _InlineUnavailable(reason: '还没有问过这台主机的设备');
    }
    if (inventory.devices.isEmpty) {
      return Text('还没有设备挂到这个伙伴身上', style: theme.textTheme.bodyMedium);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final device in inventory.devices)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                const Icon(Icons.memory_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(device.label)),
                if (device.attachedCompanionId == companionId)
                  Text('已附体', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
      ],
    );
  }
}

/// The dials the console's cockpit does not have.
///
/// Disk, memory, load, temperature — read through the Local API because the
/// phone is what an Owner has in their hand when a Host stops answering. The
/// judgement of what counts as too little was already made Host-side; this
/// screen shows the verdict rather than re-deciding it, so the two cannot
/// drift apart.
class _VitalsSection extends StatelessWidget {
  const _VitalsSection({required this.lane, required this.onRetry});

  final _Lane<HostVitals> lane;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => _Section<HostVitals>(
        key: const Key('cockpit-vitals'),
        title: '生命体征',
        lane: lane,
        onRetry: onRetry,
        builder: (vitals) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final vital in vitals.vitals)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    _ConcernDot(vital: vital),
                    const SizedBox(width: 10),
                    Expanded(child: Text(vital.name)),
                    Text(
                      vital.reading,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
}

/// Three states, and unknown is one of them.
///
/// A reading the Host could not take gets its own mark rather than a green
/// tick — a tick would claim the machine is healthy on exactly the evidence
/// that is missing.
class _ConcernDot extends StatelessWidget {
  const _ConcernDot({required this.vital});

  final HostVital vital;

  @override
  Widget build(BuildContext context) {
    if (vital.isUnavailable) {
      return const Icon(Icons.help_outline, size: 16);
    }
    return Icon(
      Icons.circle,
      size: 12,
      color: switch (vital.concern) {
        VitalConcern.act => Theme.of(context).colorScheme.error,
        VitalConcern.watch => Colors.orange,
        VitalConcern.none => Colors.green,
      },
    );
  }
}

class _ServicesSection extends StatelessWidget {
  const _ServicesSection({required this.lane, required this.onRetry});

  final _Lane<HostServiceInventory> lane;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => _Section<HostServiceInventory>(
        key: const Key('cockpit-services'),
        title: '这台主机在跑什么',
        lane: lane,
        onRetry: onRetry,
        builder: (inventory) {
          final unwell = inventory.services
              .where((s) => s.runtimeState != HostServiceRuntimeState.ready)
              .toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${inventory.services.length} 项服务，${unwell.length} 项不在就绪状态'),
              if (unwell.isNotEmpty) const SizedBox(height: 8),
              for (final service in unwell)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 16,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(service.serviceId)),
                      if (service.detail case final detail?)
                        Flexible(
                          child: Text(
                            detail,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      );
}

/// Who may speak for this Owner.
///
/// The console's cockpit calls this a permission ledger. It is the same
/// question and it matters more on a phone, because this is where a person
/// would notice a device they do not recognise.
class _ControllersSection extends StatelessWidget {
  const _ControllersSection({
    required this.lane,
    required this.onRetry,
  });

  final _Lane<List<ControllerView>> lane;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => _Section<List<ControllerView>>(
        key: const Key('cockpit-controllers'),
        title: '可以管理这台主机的手机',
        lane: lane,
        onRetry: onRetry,
        builder: (grants) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final grant in grants)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    const Icon(Icons.smartphone, size: 16),
                    const SizedBox(width: 8),
                    Expanded(child: Text(grant.displayName ?? grant.controllerId)),
                    if (grant.isYou)
                      Text('本机', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
          ],
        ),
      );
}

class _ActivitySection extends StatelessWidget {
  const _ActivitySection({required this.lane, required this.onRetry});

  final _Lane<HostActivity> lane;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => _Section<HostActivity>(
        key: const Key('cockpit-activity'),
        title: '最近发生',
        lane: lane,
        onRetry: onRetry,
        builder: (activity) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final moment in activity.moments.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(hostMomentSentence(moment)),
              ),
          ],
        ),
      );
}

/// One lane, with its three states drawn apart.
class _Section<T> extends StatelessWidget {
  const _Section({
    super.key,
    required this.title,
    required this.lane,
    required this.onRetry,
    required this.builder,
  });

  final String title;
  final _Lane<T> lane;
  final VoidCallback onRetry;
  final Widget Function(T value) builder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            if (lane.loading)
              const Center(child: CircularProgressIndicator())
            else if (lane.error case final error?) ...[
              // Not an empty section. What could not be read says so where it
              // would have been, so a blank space never passes for calm.
              Text('读不到：$error', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: onRetry, child: const Text('重试')),
            ] else if (lane.value case final value?)
              builder(value),
          ],
        ),
      ),
    );
  }
}

class _InlineUnavailable extends StatelessWidget {
  const _InlineUnavailable({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Icon(Icons.help_outline, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(reason, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      );
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.title, required this.reason});

  final String title;
  final String reason;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _InlineUnavailable(reason: reason),
            ],
          ),
        ),
      );
}

/// The dials that are missing, named.
///
/// The console's cockpit had these when it read the product database directly.
/// No authority publishes them over HTTP, so neither screen can show them —
/// and a cockpit that simply omits them teaches its reader that this Host has
/// no conversations and no jobs, which is a different and false thing.
class _NotPublished extends StatelessWidget {
  const _NotPublished();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('cockpit-not-published'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('这台主机不提供', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '以下几项没有任何权威在对外发布，所以这里不显示，'
              '而不是显示为空：对话记录、后台任务、Guard 绑定、记忆领域清单。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}


/// What the Host says about this Eidolon's runtime, in words.
///
/// Unknown is said out loud rather than shown as "not running": the panel used
/// to call an Eidolon 运行中 whenever the Owner had a default one, which read a
/// routing setting as a runtime state and could only ever describe one of them.
String _runtimeLine(HostCompanion companion) {
  switch (companion.running) {
    case true:
      return '主机正在运行它';
    case false:
      return '主机现在没有在运行它';
    default:
      return '运行状态读不到';
  }
}
