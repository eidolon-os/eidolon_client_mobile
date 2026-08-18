import 'package:flutter/material.dart';

import '../device_management/mounted_device_models.dart';
import 'activity_models.dart';
import 'host_service_models.dart';

/// One screen for "what is this Eidolon OS doing, and what happened lately".
///
/// It is built out of what this Host can actually answer, and says plainly
/// what it cannot. There is no presence signal anywhere in this system — no
/// heartbeat, no last-seen — so this screen never claims a device is online.
/// A green dot nobody is feeding is worse than no dot at all.
///
/// Each of the three things it shows is asked for separately and can fail
/// separately. A section that could not be read says so, in its own place,
/// and never renders as an empty one: a whole day was spent looking for a
/// device that had in fact arrived, because a failure upstream reached a
/// screen looking exactly like "nothing happened".
class MissionControlPage extends StatefulWidget {
  const MissionControlPage({
    super.key,
    required this.loadActivity,
    required this.listServices,
    this.devices,
    this.devicesError,
  });

  final Future<HostActivity> Function() loadActivity;
  final Future<HostServiceInventory> Function() listServices;

  /// What the Host already said about this Owner's devices, if it was asked
  /// before this screen opened. Null with no error means nobody has asked.
  final MountedDeviceInventory? devices;
  final String? devicesError;

  @override
  State<MissionControlPage> createState() => _MissionControlPageState();
}

class _MissionControlPageState extends State<MissionControlPage> {
  HostActivity? _activity;
  String? _activityError;
  bool _loadingActivity = true;

  HostServiceInventory? _services;
  String? _servicesError;
  bool _loadingServices = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => Future.wait([_loadActivity(), _loadServices()]);

  Future<void> _loadActivity() async {
    setState(() {
      _loadingActivity = true;
      _activityError = null;
    });
    try {
      final activity = await widget.loadActivity();
      if (!mounted) return;
      setState(() {
        _activity = activity;
        _loadingActivity = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        // Kept apart from the list: an unread history is not an empty one.
        _activityError = '没能读到发生过什么：$error';
        _activity = null;
        _loadingActivity = false;
      });
    }
  }

  Future<void> _loadServices() async {
    setState(() {
      _loadingServices = true;
      _servicesError = null;
    });
    try {
      final services = await widget.listServices();
      if (!mounted) return;
      setState(() {
        _services = services;
        _loadingServices = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _servicesError = '没能读到主机在跑什么：$error';
        _services = null;
        _loadingServices = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('mission-control-page'),
        appBar: AppBar(title: const Text('主机动态')),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _NowCard(
                loading: _loadingServices,
                services: _services,
                servicesError: _servicesError,
                devices: widget.devices,
                devicesError: widget.devicesError,
                onRetry: _loadServices,
              ),
              const SizedBox(height: 16),
              Text('最近发生', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (_loadingActivity)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    key: Key('mission-control-activity-loading'),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_activityError case final failure?)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          failure,
                          key: const Key('mission-control-activity-failure'),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton(
                          key: const Key('retry-mission-control-activity'),
                          onPressed: _loadActivity,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                )
              else if (_activity?.moments.isEmpty ?? true)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text(
                      '这台主机还没有记下设备的来去。',
                      key: Key('mission-control-activity-empty'),
                    ),
                  ),
                )
              else
                ..._activity!.moments.map(_MomentTile.new),
              const SizedBox(height: 12),
              Text(
                // What this screen does not know, said out loud rather than
                // implied by a short list.
                '这里只记录设备的到来、接受和移除。这台主机不记录设备是否在线，所以这一屏不说谁在线。',
                key: const Key('mission-control-coverage'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
}

class _NowCard extends StatelessWidget {
  const _NowCard({
    required this.loading,
    required this.services,
    required this.servicesError,
    required this.devices,
    required this.devicesError,
    required this.onRetry,
  });

  final bool loading;
  final HostServiceInventory? services;
  final String? servicesError;
  final MountedDeviceInventory? devices;
  final String? devicesError;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final all = services?.services ?? const <HostService>[];
    final running = all
        .where((item) => item.runtimeState == HostServiceRuntimeState.ready)
        .length;
    final unwell = all
        .where((item) => item.runtimeState != HostServiceRuntimeState.ready)
        .toList(growable: false);
    return Card(
      key: const Key('mission-control-now'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('此刻', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              )
            else if (servicesError case final failure?) ...[
              Text(
                failure,
                key: const Key('mission-control-services-failure'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('retry-mission-control-services'),
                onPressed: onRetry,
                child: const Text('重试'),
              ),
            ] else ...[
              Text(
                '$running/${all.length} 个服务在正常运行',
                key: const Key('mission-control-services'),
              ),
              if (unwell.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    unwell
                        .map((item) =>
                            '${item.serviceId} ${hostServiceStateLabel(item.runtimeState)}')
                        .join('、'),
                    key: const Key('mission-control-services-unwell'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
            const SizedBox(height: 10),
            if (devicesError case final failure?)
              Text(
                failure,
                key: const Key('mission-control-devices-failure'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else if (devices case final inventory?)
              Text(
                inventory.devices.isEmpty
                    ? '还没有设备挂在它上面。'
                    : '${inventory.devices.length} 台设备挂在它上面：'
                        '${inventory.devices.map((item) => item.label).join('、')}',
                key: const Key('mission-control-devices'),
              )
            else
              const Text(
                '设备还没有问过。',
                key: Key('mission-control-devices-unasked'),
              ),
          ],
        ),
      ),
    );
  }

}

class _MomentTile extends StatelessWidget {
  const _MomentTile(this.moment);

  final HostMoment moment;

  @override
  Widget build(BuildContext context) => Card(
        key: Key('moment-${moment.eventId}'),
        child: ListTile(
          leading: Icon(_icon(moment.kind)),
          title: Text(hostMomentSentence(moment)),
          subtitle: Text(
            '${hostMomentTime(moment.occurredAt, now: DateTime.now())}'
            ' · ${hostMomentDetail(moment)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );

  static IconData _icon(HostMomentKind kind) => switch (kind) {
        HostMomentKind.deviceKnocked => Icons.door_front_door_outlined,
        HostMomentKind.deviceAccepted => Icons.check_circle_outline,
        HostMomentKind.deviceRemoved => Icons.remove_circle_outline,
        HostMomentKind.other => Icons.history,
      };
}
