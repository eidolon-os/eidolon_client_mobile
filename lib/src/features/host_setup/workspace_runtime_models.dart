import 'workspace_models.dart';

class PrimaryCompanionRuntime {
  const PrimaryCompanionRuntime({required this.companionId});

  factory PrimaryCompanionRuntime.fromJson(Map<String, dynamic> value) {
    if (value.length != 2 || value['lifecycle_state'] != 'active') {
      throw const FormatException('Local API 返回了无效的主 Companion runtime');
    }
    return PrimaryCompanionRuntime(
      companionId: _resourceId(value, 'companion_id'),
    );
  }

  final String companionId;
}

class PersonaRuntime {
  const PersonaRuntime({
    required this.genomeId,
    required this.version,
    required this.schemaVersion,
    required this.genomeHash,
    required this.realizerVersion,
  });

  factory PersonaRuntime.fromJson(Map<String, dynamic> value) {
    final version = value['version'];
    final schemaVersion = value['schema_version'];
    final genomeHash = value['genome_hash'];
    final realizerVersion = value['realizer_version'];
    if (value.length != 6 ||
        value['lifecycle_state'] != 'committed' ||
        version is! int ||
        version < 1 ||
        schemaVersion is! String ||
        schemaVersion.isEmpty ||
        schemaVersion.length > 64 ||
        genomeHash is! String ||
        genomeHash.isEmpty ||
        genomeHash.length > 80 ||
        realizerVersion is! String ||
        realizerVersion.isEmpty ||
        realizerVersion.length > 64) {
      throw const FormatException('Local API 返回了无效的 Persona runtime');
    }
    return PersonaRuntime(
      genomeId: _resourceId(value, 'genome_id'),
      version: version,
      schemaVersion: schemaVersion,
      genomeHash: genomeHash,
      realizerVersion: realizerVersion,
    );
  }

  final String genomeId;
  final int version;
  final String schemaVersion;
  final String genomeHash;
  final String realizerVersion;
}

class MemoryWorkspaceRuntime {
  const MemoryWorkspaceRuntime({required this.realmId});

  factory MemoryWorkspaceRuntime.fromJson(Map<String, dynamic> value) {
    if (value.length != 2 || value['lifecycle_state'] != 'active') {
      throw const FormatException('Local API 返回了无效的 Memory Workspace runtime');
    }
    return MemoryWorkspaceRuntime(
      realmId: _resourceId(value, 'realm_id'),
    );
  }

  final String realmId;
}

class WorkspaceRuntime {
  const WorkspaceRuntime({
    required this.operationId,
    required this.owner,
    required this.primaryCompanion,
    required this.persona,
    required this.memoryWorkspace,
  });

  factory WorkspaceRuntime.fromJson(Map<String, dynamic> value) {
    final operationId = value['operation_id'];
    final rawOwner = value['owner'];
    final rawCompanion = value['primary_companion'];
    final rawPersona = value['persona'];
    final rawMemory = value['memory_workspace'];
    if (value.length != 7 ||
        value['contract_version'] != '1' ||
        value['state'] != 'ready' ||
        operationId is! String ||
        !workspaceOperationIdPattern.hasMatch(operationId) ||
        rawOwner is! Map ||
        rawCompanion is! Map ||
        rawPersona is! Map ||
        rawMemory is! Map) {
      throw const FormatException('Local API 返回了无效的 Workspace runtime');
    }
    return WorkspaceRuntime(
      operationId: operationId,
      owner: WorkspaceOwner.fromJson(Map<String, dynamic>.from(rawOwner)),
      primaryCompanion: PrimaryCompanionRuntime.fromJson(
        Map<String, dynamic>.from(rawCompanion),
      ),
      persona: PersonaRuntime.fromJson(
        Map<String, dynamic>.from(rawPersona),
      ),
      memoryWorkspace: MemoryWorkspaceRuntime.fromJson(
        Map<String, dynamic>.from(rawMemory),
      ),
    );
  }

  final String operationId;
  final WorkspaceOwner owner;
  final PrimaryCompanionRuntime primaryCompanion;
  final PersonaRuntime persona;
  final MemoryWorkspaceRuntime memoryWorkspace;

  bool matchesWorkspace(WorkspaceStatus workspace) =>
      workspace.isReady &&
      operationId == workspace.operationId &&
      owner.ownerId == workspace.owner?.ownerId &&
      primaryCompanion.companionId == workspace.workspace?.primaryCompanionId;
}

String _resourceId(Map<String, dynamic> value, String key) {
  final resourceId = value[key];
  if (resourceId is! String || resourceId.isEmpty || resourceId.length > 64) {
    throw FormatException('Workspace runtime resource $key 无效');
  }
  return resourceId;
}
