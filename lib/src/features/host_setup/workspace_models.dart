enum WorkspaceSetupState { absent, ready }

class WorkspaceOwner {
  const WorkspaceOwner({
    required this.ownerId,
    required this.displayName,
  });

  factory WorkspaceOwner.fromJson(Map<String, dynamic> value) {
    final ownerId = value['owner_id'];
    final displayName = value['display_name'];
    if (value.length != 3 ||
        ownerId is! String ||
        ownerId.isEmpty ||
        ownerId.length > 64 ||
        displayName is! String ||
        displayName.isEmpty ||
        displayName.length > 128 ||
        value['lifecycle_state'] != 'active') {
      throw const FormatException('Local API 返回了无效的 Owner');
    }
    return WorkspaceOwner(ownerId: ownerId, displayName: displayName);
  }

  final String ownerId;
  final String displayName;
}

class WorkspaceResources {
  const WorkspaceResources({
    required this.primaryCompanionId,
    required this.personaGenomeId,
    required this.memoryRealmId,
  });

  factory WorkspaceResources.fromJson(Map<String, dynamic> value) {
    final primaryCompanionId = _resourceId(value, 'primary_companion_id');
    final personaGenomeId = _resourceId(value, 'persona_genome_id');
    final memoryRealmId = _resourceId(value, 'memory_realm_id');
    if (value.length != 4 || value['state'] != 'ready') {
      throw const FormatException('Local API 返回了无效的 Workspace resources');
    }
    return WorkspaceResources(
      primaryCompanionId: primaryCompanionId,
      personaGenomeId: personaGenomeId,
      memoryRealmId: memoryRealmId,
    );
  }

  final String primaryCompanionId;
  final String personaGenomeId;
  final String memoryRealmId;
}

class WorkspaceStatus {
  const WorkspaceStatus({
    required this.operationId,
    required this.state,
    required this.owner,
    required this.workspace,
  });

  factory WorkspaceStatus.fromJson(Map<String, dynamic> value) {
    final operationId = value['operation_id'];
    final rawState = value['state'];
    final rawOwner = value['owner'];
    final rawWorkspace = value['workspace'];
    if (value.length != 5 ||
        value['contract_version'] != '1' ||
        operationId is! String ||
        !workspaceOperationIdPattern.hasMatch(operationId) ||
        rawState is! String) {
      throw const FormatException('Local API 返回了无效的 Workspace status');
    }
    final state = switch (rawState) {
      'absent' => WorkspaceSetupState.absent,
      'ready' => WorkspaceSetupState.ready,
      _ => throw const FormatException('Local API 返回了未知的 Workspace 状态'),
    };
    if (state == WorkspaceSetupState.absent) {
      if (rawOwner != null || rawWorkspace != null) {
        throw const FormatException('尚未初始化的 Workspace 包含了业务资源');
      }
      return WorkspaceStatus(
        operationId: operationId,
        state: state,
        owner: null,
        workspace: null,
      );
    }
    if (rawOwner is! Map || rawWorkspace is! Map) {
      throw const FormatException('已就绪的 Workspace 缺少业务资源');
    }
    return WorkspaceStatus(
      operationId: operationId,
      state: state,
      owner: WorkspaceOwner.fromJson(Map<String, dynamic>.from(rawOwner)),
      workspace: WorkspaceResources.fromJson(
        Map<String, dynamic>.from(rawWorkspace),
      ),
    );
  }

  final String operationId;
  final WorkspaceSetupState state;
  final WorkspaceOwner? owner;
  final WorkspaceResources? workspace;

  bool get isReady => state == WorkspaceSetupState.ready;
}

final workspaceOperationIdPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

String _resourceId(Map<String, dynamic> value, String key) {
  final resourceId = value[key];
  if (resourceId is! String || resourceId.isEmpty || resourceId.length > 64) {
    throw FormatException('Workspace resource $key 无效');
  }
  return resourceId;
}
