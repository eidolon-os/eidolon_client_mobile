/// Host services as the Owner sees them.
///
/// The same services Admin Web manages, reached through Local API. Endpoint
/// addresses and contract ids stay on the operator side; what reaches the phone
/// is whether a service is running and the revision needed to act on it.
enum HostServiceRuntimeState {
  unknown,
  inactive,
  starting,
  ready,
  degraded,
  blocked,
  failed,
}

HostServiceRuntimeState _runtimeState(Object? value) => switch (value) {
      'unknown' => HostServiceRuntimeState.unknown,
      'inactive' => HostServiceRuntimeState.inactive,
      'starting' => HostServiceRuntimeState.starting,
      'ready' => HostServiceRuntimeState.ready,
      'degraded' => HostServiceRuntimeState.degraded,
      'blocked' => HostServiceRuntimeState.blocked,
      'failed' => HostServiceRuntimeState.failed,
      _ => throw const FormatException('Local API 返回了未知的服务运行状态'),
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

  factory HostService.fromJson(Map<String, dynamic> value) {
    final serviceId = value['service_id'];
    final revision = value['revision'];
    final observedAt = value['observed_at'];
    final detail = value['detail'];
    if (serviceId is! String ||
        serviceId.isEmpty ||
        value['required'] is! bool ||
        value['enabled'] is! bool ||
        revision is! int ||
        revision < 1 ||
        observedAt is! String ||
        (detail != null && detail is! String)) {
      throw const FormatException('Local API 返回了无效的服务条目');
    }
    return HostService(
      serviceId: serviceId,
      required: value['required'] as bool,
      enabled: value['enabled'] as bool,
      revision: revision,
      runtimeState: _runtimeState(value['runtime_state']),
      detail: detail as String?,
      observedAt: DateTime.parse(observedAt),
    );
  }

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

  factory HostServiceInventory.fromJson(Map<String, dynamic> value) {
    final rawServices = value['services'];
    if (value.length != 1 || rawServices is! List || rawServices.length > 100) {
      throw const FormatException('Local API 返回了无效的服务列表');
    }
    final services = rawServices.map((item) {
      if (item is! Map) {
        throw const FormatException('Local API 服务列表包含无效条目');
      }
      return HostService.fromJson(Map<String, dynamic>.from(item));
    }).toList(growable: false);
    if (services.map((item) => item.serviceId).toSet().length !=
        services.length) {
      throw const FormatException('Local API 服务列表包含重复服务');
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

  factory HostServiceChange.fromJson(Map<String, dynamic> value) {
    final serviceId = value['service_id'];
    final operation = value['operation'];
    final revision = value['revision'];
    if (value.length != 4 ||
        serviceId is! String ||
        serviceId.isEmpty ||
        operation is! String ||
        !const {'restart', 'enable', 'disable'}.contains(operation) ||
        value['enabled'] is! bool ||
        revision is! int ||
        revision < 1) {
      throw const FormatException('Local API 返回了无效的服务操作结果');
    }
    return HostServiceChange(
      serviceId: serviceId,
      operation: operation,
      enabled: value['enabled'] as bool,
      revision: revision,
    );
  }

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
