import '../../generated/management_v1.dart';

/// Host services as the Owner sees them.
///
/// The same services Admin Web manages, over the management contract. Endpoint
/// addresses and contract ids stay on the operator side; what reaches the phone
/// is whether a service is running and the revision needed to act on it.
///
/// Built from the generated views. The enum and its label are what this file is
/// for: the wire says "degraded" and a person reads 降级, and switching on a
/// string in five widgets is how one of them ends up spelling it differently.
enum HostServiceRuntimeState {
  unknown,
  inactive,
  starting,
  ready,
  degraded,
  blocked,
  failed,
}

HostServiceRuntimeState _runtimeState(String value) => switch (value) {
      'unknown' => HostServiceRuntimeState.unknown,
      'inactive' => HostServiceRuntimeState.inactive,
      'starting' => HostServiceRuntimeState.starting,
      'ready' => HostServiceRuntimeState.ready,
      'degraded' => HostServiceRuntimeState.degraded,
      'blocked' => HostServiceRuntimeState.blocked,
      'failed' => HostServiceRuntimeState.failed,
      // A state this version has never heard of is "unknown" rather than a
      // thrown answer: the Host may grow one, and a screen that refused to draw
      // the other nine services because of it would be worse than one that says
      // it does not know about this one.
      _ => HostServiceRuntimeState.unknown,
    };

class HostService {
  const HostService({
    required this.serviceId,
    required this.required,
    required this.enabled,
    required this.revision,
    required this.runtimeState,
    required this.detail,
    required this.observedAt,
  });

  factory HostService.fromView(HostServiceView view) => HostService(
        serviceId: view.serviceId,
        required: view.required,
        enabled: view.enabled,
        revision: view.revision,
        runtimeState: _runtimeState(view.runtimeState),
        detail: view.detail,
        observedAt: DateTime.parse(view.observedAt),
      );

  final String serviceId;
  final bool required;
  final bool enabled;

  /// Echoed back on every change so a stale screen cannot win a race.
  final int revision;
  final HostServiceRuntimeState runtimeState;
  final String? detail;
  final DateTime observedAt;
}

class HostServiceInventory {
  const HostServiceInventory({required this.services});

  factory HostServiceInventory.fromView(HostServiceInventoryView view) {
    final services =
        (view.services ?? const <HostServiceView>[])
            .map(HostService.fromView)
            .toList(growable: false);
    if (services.map((item) => item.serviceId).toSet().length !=
        services.length) {
      // Two rows for one service means one of them is stale, and a screen that
      // drew both would offer two revisions of the same thing to act on.
      throw const FormatException('主机返回了重复的服务');
    }
    return HostServiceInventory(services: services);
  }

  final List<HostService> services;
}

class HostServiceChange {
  const HostServiceChange({
    required this.serviceId,
    required this.operation,
    required this.enabled,
    required this.revision,
  });

  factory HostServiceChange.fromView(HostServiceMutationView view) =>
      HostServiceChange(
        serviceId: view.serviceId,
        operation: view.operation,
        enabled: view.enabled,
        revision: view.revision,
      );

  final String serviceId;
  final String operation;
  final bool enabled;
  final int revision;
}

String hostServiceStateLabel(HostServiceRuntimeState state) => switch (state) {
      HostServiceRuntimeState.unknown => '未知',
      HostServiceRuntimeState.inactive => '未运行',
      HostServiceRuntimeState.starting => '正在启动',
      HostServiceRuntimeState.ready => '正常',
      HostServiceRuntimeState.degraded => '降级',
      HostServiceRuntimeState.blocked => '被阻塞',
      HostServiceRuntimeState.failed => '失败',
    };
