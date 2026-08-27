// Generated from eidolon_admin/contracts/management/v1/management-v1.openapi.json.
// Do not edit by hand; contracts/management/v1/generate_dart.py owns this file
// and a test runs it with --check, so an edit here fails rather than surviving.
//
// No operation takes an ownerId: the Owner comes from the authenticated
// Controller session, so it is not expressible from a client.

/// The paths this contract describes, so a caller does not spell one.
class ManagementV1 {
  const ManagementV1._();

  static const String activityPath = '/api/management/v1/activity';
  static const String companionsPath = '/api/management/v1/companions';
  static String companionsByCompanionIdPath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}';
  static String companionsByCompanionIdConversationsPath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/conversations';
  static String companionsByCompanionIdConversationsByConversationIdTurnsPath(String companionId, String conversationId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/conversations/${Uri.encodeComponent(conversationId)}/turns';
  static String companionsByCompanionIdFacePath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/face';
  static String companionsByCompanionIdFaceStatePath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/face-state';
  static String companionsByCompanionIdLifecyclePath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/lifecycle';
  static String companionsByCompanionIdPersonaPath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/persona';
  static String companionsByCompanionIdPersonaHistoryPath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/persona-history';
  static String companionsByCompanionIdPersonaRestorationsPath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/persona-restorations';
  static String companionsByCompanionIdTasksPath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/tasks';
  static String companionsByCompanionIdTasksByTaskIdPath(String companionId, String taskId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/tasks/${Uri.encodeComponent(taskId)}';
  static String companionsByCompanionIdTasksByTaskIdCancelPath(String companionId, String taskId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/tasks/${Uri.encodeComponent(taskId)}/cancel';
  static String companionsByCompanionIdTasksByTaskIdRetryPath(String companionId, String taskId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/tasks/${Uri.encodeComponent(taskId)}/retry';
  static const String contextPath = '/api/management/v1/context';
  static const String controllersPath = '/api/management/v1/controllers';
  static const String controllersInvitationsPath = '/api/management/v1/controllers/invitations';
  static String controllersByControllerIdPath(String controllerId) => '/api/management/v1/controllers/${Uri.encodeComponent(controllerId)}';
  static const String devicesPath = '/api/management/v1/devices';
  static String devicesByDeviceIdCompanionPath(String deviceId) => '/api/management/v1/devices/${Uri.encodeComponent(deviceId)}/companion';
  static String devicesByDeviceIdRemovalPath(String deviceId) => '/api/management/v1/devices/${Uri.encodeComponent(deviceId)}/removal';
  static const String homePath = '/api/management/v1/home';
  static const String hostServicesPath = '/api/management/v1/host/services';
  static String hostServicesByServiceIdByOperationPath(String serviceId, String operation) => '/api/management/v1/host/services/${Uri.encodeComponent(serviceId)}/${Uri.encodeComponent(operation)}';
  static const String hostVitalsPath = '/api/management/v1/host/vitals';
  static const String memoryEntriesPath = '/api/management/v1/memory/entries';
  static String memoryEntriesByEntryIdAudiencePath(String entryId) => '/api/management/v1/memory/entries/${Uri.encodeComponent(entryId)}/audience';
  static const String memoryExportPath = '/api/management/v1/memory/export';
  static const String memoryForgetConfirmPath = '/api/management/v1/memory/forget/confirm';
  static const String memoryForgetPreviewPath = '/api/management/v1/memory/forget/preview';
  static const String memoryGraphPath = '/api/management/v1/memory/graph';
  static const String memoryLibraryPath = '/api/management/v1/memory/library';
  static const String memoryRecollectionsPath = '/api/management/v1/memory/recollections';
  static const String missionControlActivitiesPath = '/api/management/v1/mission-control/activities';
  static const String missionControlSnapshotPath = '/api/management/v1/mission-control/snapshot';
  static const String ownerPath = '/api/management/v1/owner';
  static const String ownerActionsRevokeRuntimeSessionsPath = '/api/management/v1/owner/actions/revoke-runtime-sessions';
  static const String ownerDefaultCompanionPath = '/api/management/v1/owner/default-companion';
  static const String personaAuthoringTemplatePath = '/api/management/v1/persona-authoring-template';
}

class ActivityMomentView {
  const ActivityMomentView({
    required this.action,
    this.detail,
    required this.eventId,
    required this.occurredAt,
    required this.outcome,
    required this.subjectId,
    this.subjectName,
    required this.subjectType,
  });

  final String action;

  final Map<String, String>? detail;

  final String eventId;

  final String occurredAt;

  final String outcome;

  final String subjectId;

  final String? subjectName;

  final String subjectType;

  factory ActivityMomentView.fromJson(Map<String, dynamic> value) {
    return ActivityMomentView(
      action: value['action'] as String,
      detail: value['detail'] == null ? null : ((value['detail'] as Map<String, dynamic>).map((key, entry) => MapEntry(key, entry as String))),
      eventId: value['event_id'] as String,
      occurredAt: value['occurred_at'] as String,
      outcome: value['outcome'] as String,
      subjectId: value['subject_id'] as String,
      subjectName: value['subject_name'] as String?,
      subjectType: value['subject_type'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'action': action,
      if (detail != null) 'detail': detail,
      'event_id': eventId,
      'occurred_at': occurredAt,
      'outcome': outcome,
      'subject_id': subjectId,
      if (subjectName != null) 'subject_name': subjectName,
      'subject_type': subjectType,
    };
  }
}

class ActivityView {
  const ActivityView({
    this.contractVersion,
    required this.moments,
    this.nextCursor,
  });

  final String? contractVersion;

  final List<ActivityMomentView> moments;

  final String? nextCursor;

  factory ActivityView.fromJson(Map<String, dynamic> value) {
    return ActivityView(
      contractVersion: value['contract_version'] as String?,
      moments: ((value['moments'] as List<dynamic>).map((entry) => ActivityMomentView.fromJson(entry as Map<String, dynamic>)).toList()),
      nextCursor: value['next_cursor'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      'moments': moments.map((entry) => entry.toJson()).toList(),
      if (nextCursor != null) 'next_cursor': nextCursor,
    };
  }
}

class CompanionCreateRequest {
  const CompanionCreateRequest({
    required this.displayName,
    this.kind,
    required this.operationId,
    this.persona,
  });

  final String displayName;

  final String? kind;

  final String operationId;

  final PersonaAuthoring? persona;

  factory CompanionCreateRequest.fromJson(Map<String, dynamic> value) {
    return CompanionCreateRequest(
      displayName: value['display_name'] as String,
      kind: value['kind'] as String?,
      operationId: value['operation_id'] as String,
      persona: value['persona'] == null ? null : PersonaAuthoring.fromJson(value['persona'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'display_name': displayName,
      if (kind != null) 'kind': kind,
      'operation_id': operationId,
      if (persona != null) 'persona': persona?.toJson(),
    };
  }
}

class CompanionCreatedView {
  const CompanionCreatedView({
    required this.companionId,
    this.contractVersion,
    required this.created,
    this.displayName,
    required this.kind,
    required this.lifecycleState,
    required this.memoryReady,
    required this.revision,
  });

  final String companionId;

  final String? contractVersion;

  final bool created;

  final String? displayName;

  final String kind;

  final String lifecycleState;

  final bool memoryReady;

  final int revision;

  factory CompanionCreatedView.fromJson(Map<String, dynamic> value) {
    return CompanionCreatedView(
      companionId: value['companion_id'] as String,
      contractVersion: value['contract_version'] as String?,
      created: value['created'] as bool,
      displayName: value['display_name'] as String?,
      kind: value['kind'] as String,
      lifecycleState: value['lifecycle_state'] as String,
      memoryReady: value['memory_ready'] as bool,
      revision: value['revision'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'companion_id': companionId,
      if (contractVersion != null) 'contract_version': contractVersion,
      'created': created,
      if (displayName != null) 'display_name': displayName,
      'kind': kind,
      'lifecycle_state': lifecycleState,
      'memory_ready': memoryReady,
      'revision': revision,
    };
  }
}

class CompanionDetailView {
  const CompanionDetailView({
    required this.companionId,
    this.contractVersion,
    this.displayName,
    required this.isDefault,
    required this.kind,
    this.lastActiveAt,
    required this.lifecycleState,
    this.personaChapter,
    required this.revision,
    this.running,
  });

  final String companionId;

  final String? contractVersion;

  final String? displayName;

  final bool isDefault;

  final String kind;

  final String? lastActiveAt;

  final String lifecycleState;

  final String? personaChapter;

  final int revision;

  final bool? running;

  factory CompanionDetailView.fromJson(Map<String, dynamic> value) {
    return CompanionDetailView(
      companionId: value['companion_id'] as String,
      contractVersion: value['contract_version'] as String?,
      displayName: value['display_name'] as String?,
      isDefault: value['is_default'] as bool,
      kind: value['kind'] as String,
      lastActiveAt: value['last_active_at'] as String?,
      lifecycleState: value['lifecycle_state'] as String,
      personaChapter: value['persona_chapter'] as String?,
      revision: value['revision'] as int,
      running: value['running'] as bool?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'companion_id': companionId,
      if (contractVersion != null) 'contract_version': contractVersion,
      if (displayName != null) 'display_name': displayName,
      'is_default': isDefault,
      'kind': kind,
      if (lastActiveAt != null) 'last_active_at': lastActiveAt,
      'lifecycle_state': lifecycleState,
      if (personaChapter != null) 'persona_chapter': personaChapter,
      'revision': revision,
      if (running != null) 'running': running,
    };
  }
}

class CompanionFaceView {
  const CompanionFaceView({
    required this.companionId,
    this.contractVersion,
    required this.hasFace,
    this.sha256,
    this.updatedAt,
  });

  final String companionId;

  final String? contractVersion;

  final bool hasFace;

  final String? sha256;

  final String? updatedAt;

  factory CompanionFaceView.fromJson(Map<String, dynamic> value) {
    return CompanionFaceView(
      companionId: value['companion_id'] as String,
      contractVersion: value['contract_version'] as String?,
      hasFace: value['has_face'] as bool,
      sha256: value['sha256'] as String?,
      updatedAt: value['updated_at'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'companion_id': companionId,
      if (contractVersion != null) 'contract_version': contractVersion,
      'has_face': hasFace,
      if (sha256 != null) 'sha256': sha256,
      if (updatedAt != null) 'updated_at': updatedAt,
    };
  }
}

class CompanionLifecycleRequest {
  const CompanionLifecycleRequest({
    this.expectedRevision,
    required this.lifecycleState,
    this.replacementCompanionId,
  });

  final int? expectedRevision;

  final String lifecycleState;

  final String? replacementCompanionId;

  factory CompanionLifecycleRequest.fromJson(Map<String, dynamic> value) {
    return CompanionLifecycleRequest(
      expectedRevision: value['expected_revision'] as int?,
      lifecycleState: value['lifecycle_state'] as String,
      replacementCompanionId: value['replacement_companion_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (expectedRevision != null) 'expected_revision': expectedRevision,
      'lifecycle_state': lifecycleState,
      if (replacementCompanionId != null) 'replacement_companion_id': replacementCompanionId,
    };
  }
}

class CompanionLifecycleView {
  const CompanionLifecycleView({
    required this.companionId,
    this.contractVersion,
    this.defaultCompanionId,
    required this.lifecycleState,
    this.releasedDevices,
    required this.revision,
  });

  final String companionId;

  final String? contractVersion;

  final String? defaultCompanionId;

  final String lifecycleState;

  final List<String>? releasedDevices;

  final int revision;

  factory CompanionLifecycleView.fromJson(Map<String, dynamic> value) {
    return CompanionLifecycleView(
      companionId: value['companion_id'] as String,
      contractVersion: value['contract_version'] as String?,
      defaultCompanionId: value['default_companion_id'] as String?,
      lifecycleState: value['lifecycle_state'] as String,
      releasedDevices: value['released_devices'] == null ? null : ((value['released_devices'] as List<dynamic>).map((entry) => entry as String).toList()),
      revision: value['revision'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'companion_id': companionId,
      if (contractVersion != null) 'contract_version': contractVersion,
      if (defaultCompanionId != null) 'default_companion_id': defaultCompanionId,
      'lifecycle_state': lifecycleState,
      if (releasedDevices != null) 'released_devices': releasedDevices,
      'revision': revision,
    };
  }
}

class CompanionNameView {
  const CompanionNameView({
    required this.companionId,
    this.contractVersion,
    this.displayName,
    required this.revision,
  });

  final String companionId;

  final String? contractVersion;

  final String? displayName;

  final int revision;

  factory CompanionNameView.fromJson(Map<String, dynamic> value) {
    return CompanionNameView(
      companionId: value['companion_id'] as String,
      contractVersion: value['contract_version'] as String?,
      displayName: value['display_name'] as String?,
      revision: value['revision'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'companion_id': companionId,
      if (contractVersion != null) 'contract_version': contractVersion,
      if (displayName != null) 'display_name': displayName,
      'revision': revision,
    };
  }
}

class CompanionRosterView {
  const CompanionRosterView({
    required this.companions,
    this.contractVersion,
    this.defaultCompanionId,
    this.nextCursor,
    this.runtimeUnavailable,
  });

  final List<CompanionSummaryView> companions;

  final String? contractVersion;

  final String? defaultCompanionId;

  final String? nextCursor;

  final String? runtimeUnavailable;

  factory CompanionRosterView.fromJson(Map<String, dynamic> value) {
    return CompanionRosterView(
      companions: ((value['companions'] as List<dynamic>).map((entry) => CompanionSummaryView.fromJson(entry as Map<String, dynamic>)).toList()),
      contractVersion: value['contract_version'] as String?,
      defaultCompanionId: value['default_companion_id'] as String?,
      nextCursor: value['next_cursor'] as String?,
      runtimeUnavailable: value['runtime_unavailable'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'companions': companions.map((entry) => entry.toJson()).toList(),
      if (contractVersion != null) 'contract_version': contractVersion,
      if (defaultCompanionId != null) 'default_companion_id': defaultCompanionId,
      if (nextCursor != null) 'next_cursor': nextCursor,
      if (runtimeUnavailable != null) 'runtime_unavailable': runtimeUnavailable,
    };
  }
}

class CompanionSummaryView {
  const CompanionSummaryView({
    required this.companionId,
    required this.createdAt,
    this.displayName,
    this.genomeId,
    required this.kind,
    this.lastActiveAt,
    required this.lifecycleState,
    this.memoryRealmId,
    required this.revision,
    this.running,
    required this.updatedAt,
  });

  final String companionId;

  final String createdAt;

  final String? displayName;

  final String? genomeId;

  final String kind;

  final String? lastActiveAt;

  final String lifecycleState;

  final String? memoryRealmId;

  final int revision;

  final bool? running;

  final String updatedAt;

  factory CompanionSummaryView.fromJson(Map<String, dynamic> value) {
    return CompanionSummaryView(
      companionId: value['companion_id'] as String,
      createdAt: value['created_at'] as String,
      displayName: value['display_name'] as String?,
      genomeId: value['genome_id'] as String?,
      kind: value['kind'] as String,
      lastActiveAt: value['last_active_at'] as String?,
      lifecycleState: value['lifecycle_state'] as String,
      memoryRealmId: value['memory_realm_id'] as String?,
      revision: value['revision'] as int,
      running: value['running'] as bool?,
      updatedAt: value['updated_at'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'companion_id': companionId,
      'created_at': createdAt,
      if (displayName != null) 'display_name': displayName,
      if (genomeId != null) 'genome_id': genomeId,
      'kind': kind,
      if (lastActiveAt != null) 'last_active_at': lastActiveAt,
      'lifecycle_state': lifecycleState,
      if (memoryRealmId != null) 'memory_realm_id': memoryRealmId,
      'revision': revision,
      if (running != null) 'running': running,
      'updated_at': updatedAt,
    };
  }
}

class ControllerInvitationRequest {
  const ControllerInvitationRequest({
    this.ttlSeconds,
  });

  final int? ttlSeconds;

  factory ControllerInvitationRequest.fromJson(Map<String, dynamic> value) {
    return ControllerInvitationRequest(
      ttlSeconds: value['ttl_seconds'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (ttlSeconds != null) 'ttl_seconds': ttlSeconds,
    };
  }
}

class ControllerInvitationView {
  const ControllerInvitationView({
    this.contractVersion,
    required this.expiresAt,
    required this.setupCode,
  });

  final String? contractVersion;

  final String expiresAt;

  final String setupCode;

  factory ControllerInvitationView.fromJson(Map<String, dynamic> value) {
    return ControllerInvitationView(
      contractVersion: value['contract_version'] as String?,
      expiresAt: value['expires_at'] as String,
      setupCode: value['setup_code'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      'expires_at': expiresAt,
      'setup_code': setupCode,
    };
  }
}

class ControllerView {
  const ControllerView({
    required this.claimedAt,
    required this.controllerId,
    this.displayName,
    this.fingerprint,
    required this.isYou,
    this.platform,
    required this.role,
  });

  final String claimedAt;

  final String controllerId;

  final String? displayName;

  final String? fingerprint;

  final bool isYou;

  final String? platform;

  final String role;

  factory ControllerView.fromJson(Map<String, dynamic> value) {
    return ControllerView(
      claimedAt: value['claimed_at'] as String,
      controllerId: value['controller_id'] as String,
      displayName: value['display_name'] as String?,
      fingerprint: value['fingerprint'] as String?,
      isYou: value['is_you'] as bool,
      platform: value['platform'] as String?,
      role: value['role'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'claimed_at': claimedAt,
      'controller_id': controllerId,
      if (displayName != null) 'display_name': displayName,
      if (fingerprint != null) 'fingerprint': fingerprint,
      'is_you': isYou,
      if (platform != null) 'platform': platform,
      'role': role,
    };
  }
}

class ControllersView {
  const ControllersView({
    this.contractVersion,
    required this.controllers,
  });

  final String? contractVersion;

  final List<ControllerView> controllers;

  factory ControllersView.fromJson(Map<String, dynamic> value) {
    return ControllersView(
      contractVersion: value['contract_version'] as String?,
      controllers: ((value['controllers'] as List<dynamic>).map((entry) => ControllerView.fromJson(entry as Map<String, dynamic>)).toList()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      'controllers': controllers.map((entry) => entry.toJson()).toList(),
    };
  }
}

class ConversationPageView {
  const ConversationPageView({
    required this.companionId,
    this.contractVersion,
    required this.conversations,
    this.nextCursor,
  });

  final String companionId;

  final String? contractVersion;

  final List<ConversationView> conversations;

  final String? nextCursor;

  factory ConversationPageView.fromJson(Map<String, dynamic> value) {
    return ConversationPageView(
      companionId: value['companion_id'] as String,
      contractVersion: value['contract_version'] as String?,
      conversations: ((value['conversations'] as List<dynamic>).map((entry) => ConversationView.fromJson(entry as Map<String, dynamic>)).toList()),
      nextCursor: value['next_cursor'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'companion_id': companionId,
      if (contractVersion != null) 'contract_version': contractVersion,
      'conversations': conversations.map((entry) => entry.toJson()).toList(),
      if (nextCursor != null) 'next_cursor': nextCursor,
    };
  }
}

class ConversationView {
  const ConversationView({
    required this.conversationId,
    this.endedAt,
    this.startedAt,
    this.title,
    this.updatedAt,
  });

  final String conversationId;

  final String? endedAt;

  final String? startedAt;

  final String? title;

  final String? updatedAt;

  factory ConversationView.fromJson(Map<String, dynamic> value) {
    return ConversationView(
      conversationId: value['conversation_id'] as String,
      endedAt: value['ended_at'] as String?,
      startedAt: value['started_at'] as String?,
      title: value['title'] as String?,
      updatedAt: value['updated_at'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'conversation_id': conversationId,
      if (endedAt != null) 'ended_at': endedAt,
      if (startedAt != null) 'started_at': startedAt,
      if (title != null) 'title': title,
      if (updatedAt != null) 'updated_at': updatedAt,
    };
  }
}

class DefaultCompanionRequest {
  const DefaultCompanionRequest({
    required this.companionId,
    required this.expectedRevision,
  });

  final String companionId;

  final int expectedRevision;

  factory DefaultCompanionRequest.fromJson(Map<String, dynamic> value) {
    return DefaultCompanionRequest(
      companionId: value['companion_id'] as String,
      expectedRevision: value['expected_revision'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'companion_id': companionId,
      'expected_revision': expectedRevision,
    };
  }
}

class DefaultCompanionView {
  const DefaultCompanionView({
    this.contractVersion,
    this.defaultCompanionId,
  });

  final String? contractVersion;

  final String? defaultCompanionId;

  factory DefaultCompanionView.fromJson(Map<String, dynamic> value) {
    return DefaultCompanionView(
      contractVersion: value['contract_version'] as String?,
      defaultCompanionId: value['default_companion_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      if (defaultCompanionId != null) 'default_companion_id': defaultCompanionId,
    };
  }
}

class DeviceCompanionRequest {
  const DeviceCompanionRequest({
    this.companionId,
    required this.expectedRevision,
    required this.requestId,
  });

  final String? companionId;

  final int expectedRevision;

  final String requestId;

  factory DeviceCompanionRequest.fromJson(Map<String, dynamic> value) {
    return DeviceCompanionRequest(
      companionId: value['companion_id'] as String?,
      expectedRevision: value['expected_revision'] as int,
      requestId: value['request_id'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (companionId != null) 'companion_id': companionId,
      'expected_revision': expectedRevision,
      'request_id': requestId,
    };
  }
}

class DeviceRemovalConditionView {
  const DeviceRemovalConditionView({
    required this.authority,
    required this.name,
    this.observedAt,
    required this.state,
  });

  final String authority;

  final String name;

  final String? observedAt;

  final String state;

  factory DeviceRemovalConditionView.fromJson(Map<String, dynamic> value) {
    return DeviceRemovalConditionView(
      authority: value['authority'] as String,
      name: value['name'] as String,
      observedAt: value['observed_at'] as String?,
      state: value['state'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'authority': authority,
      'name': name,
      if (observedAt != null) 'observed_at': observedAt,
      'state': state,
    };
  }
}

class DeviceRemovalRequest {
  const DeviceRemovalRequest({
    required this.requestId,
  });

  final String requestId;

  factory DeviceRemovalRequest.fromJson(Map<String, dynamic> value) {
    return DeviceRemovalRequest(
      requestId: value['request_id'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'request_id': requestId,
    };
  }
}

class DeviceRemovalView {
  const DeviceRemovalView({
    required this.conditions,
    this.contractVersion,
    required this.deviceId,
    required this.outcome,
    required this.requestId,
  });

  final List<DeviceRemovalConditionView> conditions;

  final String? contractVersion;

  final String deviceId;

  final String outcome;

  final String requestId;

  factory DeviceRemovalView.fromJson(Map<String, dynamic> value) {
    return DeviceRemovalView(
      conditions: ((value['conditions'] as List<dynamic>).map((entry) => DeviceRemovalConditionView.fromJson(entry as Map<String, dynamic>)).toList()),
      contractVersion: value['contract_version'] as String?,
      deviceId: value['device_id'] as String,
      outcome: value['outcome'] as String,
      requestId: value['request_id'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'conditions': conditions.map((entry) => entry.toJson()).toList(),
      if (contractVersion != null) 'contract_version': contractVersion,
      'device_id': deviceId,
      'outcome': outcome,
      'request_id': requestId,
    };
  }
}

class DeviceView {
  const DeviceView({
    this.answersAsCompanionId,
    this.answersAsCompanionName,
    required this.claimGeneration,
    required this.claimState,
    required this.deviceId,
    this.kind,
    required this.label,
    this.manifestId,
    this.manifestRevision,
    required this.mountRevision,
    this.online,
    this.onlineReason,
    required this.ownerDomainGeneration,
    this.quietBecause,
    required this.revision,
    required this.state,
    required this.trustEpoch,
    required this.updatedAt,
  });

  final String? answersAsCompanionId;

  final String? answersAsCompanionName;

  final int claimGeneration;

  final String claimState;

  final String deviceId;

  final String? kind;

  final String label;

  final String? manifestId;

  final int? manifestRevision;

  final int mountRevision;

  final String? online;

  final String? onlineReason;

  final int ownerDomainGeneration;

  final String? quietBecause;

  final int revision;

  final String state;

  final int trustEpoch;

  final String updatedAt;

  factory DeviceView.fromJson(Map<String, dynamic> value) {
    return DeviceView(
      answersAsCompanionId: value['answers_as_companion_id'] as String?,
      answersAsCompanionName: value['answers_as_companion_name'] as String?,
      claimGeneration: value['claim_generation'] as int,
      claimState: value['claim_state'] as String,
      deviceId: value['device_id'] as String,
      kind: value['kind'] as String?,
      label: value['label'] as String,
      manifestId: value['manifest_id'] as String?,
      manifestRevision: value['manifest_revision'] as int?,
      mountRevision: value['mount_revision'] as int,
      online: value['online'] as String?,
      onlineReason: value['online_reason'] as String?,
      ownerDomainGeneration: value['owner_domain_generation'] as int,
      quietBecause: value['quiet_because'] as String?,
      revision: value['revision'] as int,
      state: value['state'] as String,
      trustEpoch: value['trust_epoch'] as int,
      updatedAt: value['updated_at'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (answersAsCompanionId != null) 'answers_as_companion_id': answersAsCompanionId,
      if (answersAsCompanionName != null) 'answers_as_companion_name': answersAsCompanionName,
      'claim_generation': claimGeneration,
      'claim_state': claimState,
      'device_id': deviceId,
      if (kind != null) 'kind': kind,
      'label': label,
      if (manifestId != null) 'manifest_id': manifestId,
      if (manifestRevision != null) 'manifest_revision': manifestRevision,
      'mount_revision': mountRevision,
      if (online != null) 'online': online,
      if (onlineReason != null) 'online_reason': onlineReason,
      'owner_domain_generation': ownerDomainGeneration,
      if (quietBecause != null) 'quiet_because': quietBecause,
      'revision': revision,
      'state': state,
      'trust_epoch': trustEpoch,
      'updated_at': updatedAt,
    };
  }
}

class DevicesView {
  const DevicesView({
    this.contractVersion,
    this.coverage,
    required this.devices,
  });

  final String? contractVersion;

  final String? coverage;

  final List<DeviceView> devices;

  factory DevicesView.fromJson(Map<String, dynamic> value) {
    return DevicesView(
      contractVersion: value['contract_version'] as String?,
      coverage: value['coverage'] as String?,
      devices: ((value['devices'] as List<dynamic>).map((entry) => DeviceView.fromJson(entry as Map<String, dynamic>)).toList()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      if (coverage != null) 'coverage': coverage,
      'devices': devices.map((entry) => entry.toJson()).toList(),
    };
  }
}

class ForgetConfirmRequest {
  const ForgetConfirmRequest({
    required this.confirmationToken,
  });

  final String confirmationToken;

  factory ForgetConfirmRequest.fromJson(Map<String, dynamic> value) {
    return ForgetConfirmRequest(
      confirmationToken: value['confirmation_token'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'confirmation_token': confirmationToken,
    };
  }
}

class ForgetEntryView {
  const ForgetEntryView({
    required this.entryId,
    this.preview,
    required this.score,
  });

  final String entryId;

  final String? preview;

  final double score;

  factory ForgetEntryView.fromJson(Map<String, dynamic> value) {
    return ForgetEntryView(
      entryId: value['entry_id'] as String,
      preview: value['preview'] as String?,
      score: value['score'] as double,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'entry_id': entryId,
      if (preview != null) 'preview': preview,
      'score': score,
    };
  }
}

class ForgetProposalView {
  const ForgetProposalView({
    this.action,
    this.confirmationToken,
    this.contractVersion,
    this.detail,
    required this.entries,
    this.expiresAt,
    required this.needsConfirmation,
    required this.status,
    required this.target,
  });

  final String? action;

  final String? confirmationToken;

  final String? contractVersion;

  final String? detail;

  final List<ForgetEntryView> entries;

  final int? expiresAt;

  final bool needsConfirmation;

  final String status;

  final String target;

  factory ForgetProposalView.fromJson(Map<String, dynamic> value) {
    return ForgetProposalView(
      action: value['action'] as String?,
      confirmationToken: value['confirmation_token'] as String?,
      contractVersion: value['contract_version'] as String?,
      detail: value['detail'] as String?,
      entries: ((value['entries'] as List<dynamic>).map((entry) => ForgetEntryView.fromJson(entry as Map<String, dynamic>)).toList()),
      expiresAt: value['expires_at'] as int?,
      needsConfirmation: value['needs_confirmation'] as bool,
      status: value['status'] as String,
      target: value['target'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (action != null) 'action': action,
      if (confirmationToken != null) 'confirmation_token': confirmationToken,
      if (contractVersion != null) 'contract_version': contractVersion,
      if (detail != null) 'detail': detail,
      'entries': entries.map((entry) => entry.toJson()).toList(),
      if (expiresAt != null) 'expires_at': expiresAt,
      'needs_confirmation': needsConfirmation,
      'status': status,
      'target': target,
    };
  }
}

class ForgetResultView {
  const ForgetResultView({
    required this.action,
    this.contractVersion,
    required this.entryCount,
    required this.status,
    required this.target,
  });

  final String action;

  final String? contractVersion;

  final int entryCount;

  final String status;

  final String target;

  factory ForgetResultView.fromJson(Map<String, dynamic> value) {
    return ForgetResultView(
      action: value['action'] as String,
      contractVersion: value['contract_version'] as String?,
      entryCount: value['entry_count'] as int,
      status: value['status'] as String,
      target: value['target'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'action': action,
      if (contractVersion != null) 'contract_version': contractVersion,
      'entry_count': entryCount,
      'status': status,
      'target': target,
    };
  }
}

class ForgetTargetRequest {
  const ForgetTargetRequest({
    this.action,
    required this.target,
  });

  final String? action;

  final String target;

  factory ForgetTargetRequest.fromJson(Map<String, dynamic> value) {
    return ForgetTargetRequest(
      action: value['action'] as String?,
      target: value['target'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (action != null) 'action': action,
      'target': target,
    };
  }
}

class HomeCountsView {
  const HomeCountsView({
    required this.putAway,
    required this.ready,
    required this.total,
    required this.waiting,
  });

  final int putAway;

  final int ready;

  final int total;

  final int waiting;

  factory HomeCountsView.fromJson(Map<String, dynamic> value) {
    return HomeCountsView(
      putAway: value['put_away'] as int,
      ready: value['ready'] as int,
      total: value['total'] as int,
      waiting: value['waiting'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'put_away': putAway,
      'ready': ready,
      'total': total,
      'waiting': waiting,
    };
  }
}

class HomeView {
  const HomeView({
    required this.companionCounts,
    this.companions,
    this.contractVersion,
    this.defaultCompanionId,
    required this.devices,
    this.machineAttention,
    this.memory,
    this.ownerDisplayName,
    required this.ownerRevision,
    this.runtimeUnavailable,
    this.unavailable,
  });

  final HomeCountsView companionCounts;

  final List<CompanionSummaryView>? companions;

  final String? contractVersion;

  final String? defaultCompanionId;

  final HomeCountsView devices;

  final List<String>? machineAttention;

  final String? memory;

  final String? ownerDisplayName;

  final int ownerRevision;

  final String? runtimeUnavailable;

  final Map<String, String>? unavailable;

  factory HomeView.fromJson(Map<String, dynamic> value) {
    return HomeView(
      companionCounts: HomeCountsView.fromJson(value['companion_counts'] as Map<String, dynamic>),
      companions: value['companions'] == null ? null : ((value['companions'] as List<dynamic>).map((entry) => CompanionSummaryView.fromJson(entry as Map<String, dynamic>)).toList()),
      contractVersion: value['contract_version'] as String?,
      defaultCompanionId: value['default_companion_id'] as String?,
      devices: HomeCountsView.fromJson(value['devices'] as Map<String, dynamic>),
      machineAttention: value['machine_attention'] == null ? null : ((value['machine_attention'] as List<dynamic>).map((entry) => entry as String).toList()),
      memory: value['memory'] as String?,
      ownerDisplayName: value['owner_display_name'] as String?,
      ownerRevision: value['owner_revision'] as int,
      runtimeUnavailable: value['runtime_unavailable'] as String?,
      unavailable: value['unavailable'] == null ? null : ((value['unavailable'] as Map<String, dynamic>).map((key, entry) => MapEntry(key, entry as String))),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'companion_counts': companionCounts.toJson(),
      if (companions != null) 'companions': companions?.map((entry) => entry.toJson()).toList(),
      if (contractVersion != null) 'contract_version': contractVersion,
      if (defaultCompanionId != null) 'default_companion_id': defaultCompanionId,
      'devices': devices.toJson(),
      if (machineAttention != null) 'machine_attention': machineAttention,
      if (memory != null) 'memory': memory,
      if (ownerDisplayName != null) 'owner_display_name': ownerDisplayName,
      'owner_revision': ownerRevision,
      if (runtimeUnavailable != null) 'runtime_unavailable': runtimeUnavailable,
      if (unavailable != null) 'unavailable': unavailable,
    };
  }
}

class HostServiceInventoryView {
  const HostServiceInventoryView({
    this.services,
  });

  final List<HostServiceView>? services;

  factory HostServiceInventoryView.fromJson(Map<String, dynamic> value) {
    return HostServiceInventoryView(
      services: value['services'] == null ? null : ((value['services'] as List<dynamic>).map((entry) => HostServiceView.fromJson(entry as Map<String, dynamic>)).toList()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (services != null) 'services': services?.map((entry) => entry.toJson()).toList(),
    };
  }
}

class HostServiceMutationRequest {
  const HostServiceMutationRequest({
    required this.expectedRevision,
  });

  final int expectedRevision;

  factory HostServiceMutationRequest.fromJson(Map<String, dynamic> value) {
    return HostServiceMutationRequest(
      expectedRevision: value['expected_revision'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'expected_revision': expectedRevision,
    };
  }
}

class HostServiceMutationView {
  const HostServiceMutationView({
    required this.enabled,
    required this.operation,
    required this.revision,
    required this.serviceId,
  });

  final bool enabled;

  final String operation;

  final int revision;

  final String serviceId;

  factory HostServiceMutationView.fromJson(Map<String, dynamic> value) {
    return HostServiceMutationView(
      enabled: value['enabled'] as bool,
      operation: value['operation'] as String,
      revision: value['revision'] as int,
      serviceId: value['service_id'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'operation': operation,
      'revision': revision,
      'service_id': serviceId,
    };
  }
}

class HostServiceView {
  const HostServiceView({
    this.detail,
    required this.enabled,
    required this.observedAt,
    required this.required,
    required this.revision,
    required this.runtimeState,
    required this.serviceId,
  });

  final String? detail;

  final bool enabled;

  final String observedAt;

  final bool required;

  final int revision;

  final String runtimeState;

  final String serviceId;

  factory HostServiceView.fromJson(Map<String, dynamic> value) {
    return HostServiceView(
      detail: value['detail'] as String?,
      enabled: value['enabled'] as bool,
      observedAt: value['observed_at'] as String,
      required: value['required'] as bool,
      revision: value['revision'] as int,
      runtimeState: value['runtime_state'] as String,
      serviceId: value['service_id'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (detail != null) 'detail': detail,
      'enabled': enabled,
      'observed_at': observedAt,
      'required': required,
      'revision': revision,
      'runtime_state': runtimeState,
      'service_id': serviceId,
    };
  }
}

class HostVitalsView {
  const HostVitalsView({
    this.contractVersion,
    required this.observedAt,
    this.operation,
    this.vitals,
  });

  final String? contractVersion;

  final String observedAt;

  final String? operation;

  final List<VitalView>? vitals;

  factory HostVitalsView.fromJson(Map<String, dynamic> value) {
    return HostVitalsView(
      contractVersion: value['contract_version'] as String?,
      observedAt: value['observed_at'] as String,
      operation: value['operation'] as String?,
      vitals: value['vitals'] == null ? null : ((value['vitals'] as List<dynamic>).map((entry) => VitalView.fromJson(entry as Map<String, dynamic>)).toList()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      'observed_at': observedAt,
      if (operation != null) 'operation': operation,
      if (vitals != null) 'vitals': vitals?.map((entry) => entry.toJson()).toList(),
    };
  }
}

class ManagementContextView {
  const ManagementContextView({
    required this.capabilities,
    this.contractVersion,
    this.defaultCompanionId,
    required this.limits,
    required this.owner,
    this.unavailable,
  });

  final Map<String, bool> capabilities;

  final String? contractVersion;

  final String? defaultCompanionId;

  final Map<String, int?> limits;

  final OwnerContextView owner;

  final Map<String, String>? unavailable;

  factory ManagementContextView.fromJson(Map<String, dynamic> value) {
    return ManagementContextView(
      capabilities: ((value['capabilities'] as Map<String, dynamic>).map((key, entry) => MapEntry(key, entry as bool))),
      contractVersion: value['contract_version'] as String?,
      defaultCompanionId: value['default_companion_id'] as String?,
      limits: ((value['limits'] as Map<String, dynamic>).map((key, entry) => MapEntry(key, entry as int?))),
      owner: OwnerContextView.fromJson(value['owner'] as Map<String, dynamic>),
      unavailable: value['unavailable'] == null ? null : ((value['unavailable'] as Map<String, dynamic>).map((key, entry) => MapEntry(key, entry as String))),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'capabilities': capabilities,
      if (contractVersion != null) 'contract_version': contractVersion,
      if (defaultCompanionId != null) 'default_companion_id': defaultCompanionId,
      'limits': limits,
      'owner': owner.toJson(),
      if (unavailable != null) 'unavailable': unavailable,
    };
  }
}

class MemoryAudienceRequest {
  const MemoryAudienceRequest({
    this.companionId,
  });

  final String? companionId;

  factory MemoryAudienceRequest.fromJson(Map<String, dynamic> value) {
    return MemoryAudienceRequest(
      companionId: value['companion_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (companionId != null) 'companion_id': companionId,
    };
  }
}

class MemoryAudienceView {
  const MemoryAudienceView({
    this.companionId,
    this.contractVersion,
    required this.entryId,
    required this.status,
  });

  final String? companionId;

  final String? contractVersion;

  final String entryId;

  final String status;

  factory MemoryAudienceView.fromJson(Map<String, dynamic> value) {
    return MemoryAudienceView(
      companionId: value['companion_id'] as String?,
      contractVersion: value['contract_version'] as String?,
      entryId: value['entry_id'] as String,
      status: value['status'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (companionId != null) 'companion_id': companionId,
      if (contractVersion != null) 'contract_version': contractVersion,
      'entry_id': entryId,
      'status': status,
    };
  }
}

class MemoryCopyView {
  const MemoryCopyView({
    this.contractVersion,
    required this.recordCount,
    required this.records,
    required this.takenAt,
    required this.truncated,
    required this.undatedCount,
  });

  final String? contractVersion;

  final int recordCount;

  final List<MemoryExportRecordView> records;

  final String takenAt;

  final bool truncated;

  final int undatedCount;

  factory MemoryCopyView.fromJson(Map<String, dynamic> value) {
    return MemoryCopyView(
      contractVersion: value['contract_version'] as String?,
      recordCount: value['record_count'] as int,
      records: ((value['records'] as List<dynamic>).map((entry) => MemoryExportRecordView.fromJson(entry as Map<String, dynamic>)).toList()),
      takenAt: value['taken_at'] as String,
      truncated: value['truncated'] as bool,
      undatedCount: value['undated_count'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      'record_count': recordCount,
      'records': records.map((entry) => entry.toJson()).toList(),
      'taken_at': takenAt,
      'truncated': truncated,
      'undated_count': undatedCount,
    };
  }
}

class MemoryDayView {
  const MemoryDayView({
    this.contractVersion,
    required this.entries,
    required this.entryCount,
    required this.moreInWindow,
    required this.since,
    required this.truncated,
    required this.undatedCount,
  });

  final String? contractVersion;

  final List<MemoryEntryView> entries;

  final int entryCount;

  final bool moreInWindow;

  final String since;

  final bool truncated;

  final int undatedCount;

  factory MemoryDayView.fromJson(Map<String, dynamic> value) {
    return MemoryDayView(
      contractVersion: value['contract_version'] as String?,
      entries: ((value['entries'] as List<dynamic>).map((entry) => MemoryEntryView.fromJson(entry as Map<String, dynamic>)).toList()),
      entryCount: value['entry_count'] as int,
      moreInWindow: value['more_in_window'] as bool,
      since: value['since'] as String,
      truncated: value['truncated'] as bool,
      undatedCount: value['undated_count'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      'entries': entries.map((entry) => entry.toJson()).toList(),
      'entry_count': entryCount,
      'more_in_window': moreInWindow,
      'since': since,
      'truncated': truncated,
      'undated_count': undatedCount,
    };
  }
}

class MemoryEntryView {
  const MemoryEntryView({
    required this.entryId,
    this.preview,
    required this.recordedAt,
    this.recordedAtSource,
    this.roomId,
    this.wingId,
  });

  final String entryId;

  final String? preview;

  final String recordedAt;

  final String? recordedAtSource;

  final String? roomId;

  final String? wingId;

  factory MemoryEntryView.fromJson(Map<String, dynamic> value) {
    return MemoryEntryView(
      entryId: value['entry_id'] as String,
      preview: value['preview'] as String?,
      recordedAt: value['recorded_at'] as String,
      recordedAtSource: value['recorded_at_source'] as String?,
      roomId: value['room_id'] as String?,
      wingId: value['wing_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'entry_id': entryId,
      if (preview != null) 'preview': preview,
      'recorded_at': recordedAt,
      if (recordedAtSource != null) 'recorded_at_source': recordedAtSource,
      if (roomId != null) 'room_id': roomId,
      if (wingId != null) 'wing_id': wingId,
    };
  }
}

class MemoryExportRecordView {
  const MemoryExportRecordView({
    required this.entryId,
    this.memoryType,
    this.recordedAt,
    this.recordedAtSource,
    this.roomId,
    required this.value,
    this.wingId,
  });

  final String entryId;

  final String? memoryType;

  final String? recordedAt;

  final String? recordedAtSource;

  final String? roomId;

  final String value;

  final String? wingId;

  factory MemoryExportRecordView.fromJson(Map<String, dynamic> value) {
    return MemoryExportRecordView(
      entryId: value['entry_id'] as String,
      memoryType: value['memory_type'] as String?,
      recordedAt: value['recorded_at'] as String?,
      recordedAtSource: value['recorded_at_source'] as String?,
      roomId: value['room_id'] as String?,
      value: value['value'] as String,
      wingId: value['wing_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'entry_id': entryId,
      if (memoryType != null) 'memory_type': memoryType,
      if (recordedAt != null) 'recorded_at': recordedAt,
      if (recordedAtSource != null) 'recorded_at_source': recordedAtSource,
      if (roomId != null) 'room_id': roomId,
      'value': value,
      if (wingId != null) 'wing_id': wingId,
    };
  }
}

class MemoryGraphEdgeView {
  const MemoryGraphEdgeView({
    required this.confidence,
    required this.edgeId,
    required this.object,
    required this.predicate,
    this.recordedAt,
    required this.subject,
  });

  final double confidence;

  final String edgeId;

  final String object;

  final String predicate;

  final String? recordedAt;

  final String subject;

  factory MemoryGraphEdgeView.fromJson(Map<String, dynamic> value) {
    return MemoryGraphEdgeView(
      confidence: value['confidence'] as double,
      edgeId: value['edge_id'] as String,
      object: value['object'] as String,
      predicate: value['predicate'] as String,
      recordedAt: value['recorded_at'] as String?,
      subject: value['subject'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'confidence': confidence,
      'edge_id': edgeId,
      'object': object,
      'predicate': predicate,
      if (recordedAt != null) 'recorded_at': recordedAt,
      'subject': subject,
    };
  }
}

class MemoryGraphNodeView {
  const MemoryGraphNodeView({
    required this.degree,
    required this.label,
    required this.nodeId,
  });

  final int degree;

  final String label;

  final String nodeId;

  factory MemoryGraphNodeView.fromJson(Map<String, dynamic> value) {
    return MemoryGraphNodeView(
      degree: value['degree'] as int,
      label: value['label'] as String,
      nodeId: value['node_id'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'degree': degree,
      'label': label,
      'node_id': nodeId,
    };
  }
}

class MemoryGraphView {
  const MemoryGraphView({
    this.contractVersion,
    required this.edges,
    required this.nodes,
    required this.truncated,
  });

  final String? contractVersion;

  final List<MemoryGraphEdgeView> edges;

  final List<MemoryGraphNodeView> nodes;

  final bool truncated;

  factory MemoryGraphView.fromJson(Map<String, dynamic> value) {
    return MemoryGraphView(
      contractVersion: value['contract_version'] as String?,
      edges: ((value['edges'] as List<dynamic>).map((entry) => MemoryGraphEdgeView.fromJson(entry as Map<String, dynamic>)).toList()),
      nodes: ((value['nodes'] as List<dynamic>).map((entry) => MemoryGraphNodeView.fromJson(entry as Map<String, dynamic>)).toList()),
      truncated: value['truncated'] as bool,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      'edges': edges.map((entry) => entry.toJson()).toList(),
      'nodes': nodes.map((entry) => entry.toJson()).toList(),
      'truncated': truncated,
    };
  }
}

class MemoryLibraryView {
  const MemoryLibraryView({
    this.contractVersion,
    required this.entryCount,
    required this.truncated,
    required this.wings,
    required this.withheldCount,
  });

  final String? contractVersion;

  final int entryCount;

  final bool truncated;

  final List<MemoryWingView> wings;

  final int withheldCount;

  factory MemoryLibraryView.fromJson(Map<String, dynamic> value) {
    return MemoryLibraryView(
      contractVersion: value['contract_version'] as String?,
      entryCount: value['entry_count'] as int,
      truncated: value['truncated'] as bool,
      wings: ((value['wings'] as List<dynamic>).map((entry) => MemoryWingView.fromJson(entry as Map<String, dynamic>)).toList()),
      withheldCount: value['withheld_count'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      'entry_count': entryCount,
      'truncated': truncated,
      'wings': wings.map((entry) => entry.toJson()).toList(),
      'withheld_count': withheldCount,
    };
  }
}

class MemoryRoomView {
  const MemoryRoomView({
    required this.entryCount,
    required this.more,
    required this.roomId,
    required this.titles,
  });

  final int entryCount;

  final bool more;

  final String roomId;

  final List<String> titles;

  factory MemoryRoomView.fromJson(Map<String, dynamic> value) {
    return MemoryRoomView(
      entryCount: value['entry_count'] as int,
      more: value['more'] as bool,
      roomId: value['room_id'] as String,
      titles: ((value['titles'] as List<dynamic>).map((entry) => entry as String).toList()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'entry_count': entryCount,
      'more': more,
      'room_id': roomId,
      'titles': titles,
    };
  }
}

class MemoryWingView {
  const MemoryWingView({
    this.description,
    this.displayName,
    required this.entryCount,
    required this.rooms,
    required this.wingId,
  });

  final String? description;

  final String? displayName;

  final int entryCount;

  final List<MemoryRoomView> rooms;

  final String wingId;

  factory MemoryWingView.fromJson(Map<String, dynamic> value) {
    return MemoryWingView(
      description: value['description'] as String?,
      displayName: value['display_name'] as String?,
      entryCount: value['entry_count'] as int,
      rooms: ((value['rooms'] as List<dynamic>).map((entry) => MemoryRoomView.fromJson(entry as Map<String, dynamic>)).toList()),
      wingId: value['wing_id'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (description != null) 'description': description,
      if (displayName != null) 'display_name': displayName,
      'entry_count': entryCount,
      'rooms': rooms.map((entry) => entry.toJson()).toList(),
      'wing_id': wingId,
    };
  }
}

class OwnerContextView {
  const OwnerContextView({
    this.displayName,
    required this.ownerId,
    required this.revision,
  });

  final String? displayName;

  final String ownerId;

  final int revision;

  factory OwnerContextView.fromJson(Map<String, dynamic> value) {
    return OwnerContextView(
      displayName: value['display_name'] as String?,
      ownerId: value['owner_id'] as String,
      revision: value['revision'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (displayName != null) 'display_name': displayName,
      'owner_id': ownerId,
      'revision': revision,
    };
  }
}

class OwnerNameView {
  const OwnerNameView({
    this.contractVersion,
    this.displayName,
    required this.ownerId,
    required this.revision,
  });

  final String? contractVersion;

  final String? displayName;

  final String ownerId;

  final int revision;

  factory OwnerNameView.fromJson(Map<String, dynamic> value) {
    return OwnerNameView(
      contractVersion: value['contract_version'] as String?,
      displayName: value['display_name'] as String?,
      ownerId: value['owner_id'] as String,
      revision: value['revision'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      if (displayName != null) 'display_name': displayName,
      'owner_id': ownerId,
      'revision': revision,
    };
  }
}

class PersonaAuthoring {
  const PersonaAuthoring({
    this.archetype,
    this.behaviorGuidance,
    this.boundaries,
    this.characterPortrait,
    this.commitments,
    this.dialogueExamples,
    this.modalityNotes,
    this.pinnedFacts,
    this.relationshipNarrative,
    this.safetyBoundaries,
    this.selfConcept,
    this.traits,
    this.values,
    this.voicePortrait,
  });

  final String? archetype;

  final List<String>? behaviorGuidance;

  final List<String>? boundaries;

  final String? characterPortrait;

  final List<String>? commitments;

  final List<String>? dialogueExamples;

  final Map<String, String>? modalityNotes;

  final List<String>? pinnedFacts;

  final String? relationshipNarrative;

  final List<String>? safetyBoundaries;

  final String? selfConcept;

  final Map<String, PersonaTraitState>? traits;

  final List<String>? values;

  final String? voicePortrait;

  factory PersonaAuthoring.fromJson(Map<String, dynamic> value) {
    return PersonaAuthoring(
      archetype: value['archetype'] as String?,
      behaviorGuidance: value['behavior_guidance'] == null ? null : ((value['behavior_guidance'] as List<dynamic>).map((entry) => entry as String).toList()),
      boundaries: value['boundaries'] == null ? null : ((value['boundaries'] as List<dynamic>).map((entry) => entry as String).toList()),
      characterPortrait: value['character_portrait'] as String?,
      commitments: value['commitments'] == null ? null : ((value['commitments'] as List<dynamic>).map((entry) => entry as String).toList()),
      dialogueExamples: value['dialogue_examples'] == null ? null : ((value['dialogue_examples'] as List<dynamic>).map((entry) => entry as String).toList()),
      modalityNotes: value['modality_notes'] == null ? null : ((value['modality_notes'] as Map<String, dynamic>).map((key, entry) => MapEntry(key, entry as String))),
      pinnedFacts: value['pinned_facts'] == null ? null : ((value['pinned_facts'] as List<dynamic>).map((entry) => entry as String).toList()),
      relationshipNarrative: value['relationship_narrative'] as String?,
      safetyBoundaries: value['safety_boundaries'] == null ? null : ((value['safety_boundaries'] as List<dynamic>).map((entry) => entry as String).toList()),
      selfConcept: value['self_concept'] as String?,
      traits: value['traits'] == null ? null : ((value['traits'] as Map<String, dynamic>).map((key, entry) => MapEntry(key, PersonaTraitState.fromJson(entry as Map<String, dynamic>)))),
      values: value['values'] == null ? null : ((value['values'] as List<dynamic>).map((entry) => entry as String).toList()),
      voicePortrait: value['voice_portrait'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (archetype != null) 'archetype': archetype,
      if (behaviorGuidance != null) 'behavior_guidance': behaviorGuidance,
      if (boundaries != null) 'boundaries': boundaries,
      if (characterPortrait != null) 'character_portrait': characterPortrait,
      if (commitments != null) 'commitments': commitments,
      if (dialogueExamples != null) 'dialogue_examples': dialogueExamples,
      if (modalityNotes != null) 'modality_notes': modalityNotes,
      if (pinnedFacts != null) 'pinned_facts': pinnedFacts,
      if (relationshipNarrative != null) 'relationship_narrative': relationshipNarrative,
      if (safetyBoundaries != null) 'safety_boundaries': safetyBoundaries,
      if (selfConcept != null) 'self_concept': selfConcept,
      if (traits != null) 'traits': traits?.map((key, entry) => MapEntry(key, entry.toJson())),
      if (values != null) 'values': values,
      if (voicePortrait != null) 'voice_portrait': voicePortrait,
    };
  }
}

class PersonaChapterView {
  const PersonaChapterView({
    required this.changedAt,
    required this.chapterId,
    this.isCurrent,
    this.restoredFrom,
    this.whatChanged,
  });

  final String changedAt;

  final String chapterId;

  final bool? isCurrent;

  final int? restoredFrom;

  final String? whatChanged;

  factory PersonaChapterView.fromJson(Map<String, dynamic> value) {
    return PersonaChapterView(
      changedAt: value['changed_at'] as String,
      chapterId: value['chapter_id'] as String,
      isCurrent: value['is_current'] as bool?,
      restoredFrom: value['restored_from'] as int?,
      whatChanged: value['what_changed'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'changed_at': changedAt,
      'chapter_id': chapterId,
      if (isCurrent != null) 'is_current': isCurrent,
      if (restoredFrom != null) 'restored_from': restoredFrom,
      if (whatChanged != null) 'what_changed': whatChanged,
    };
  }
}

class PersonaHistoryView {
  const PersonaHistoryView({
    required this.chapters,
    required this.companionId,
    this.contractVersion,
  });

  final List<PersonaChapterView> chapters;

  final String companionId;

  final String? contractVersion;

  factory PersonaHistoryView.fromJson(Map<String, dynamic> value) {
    return PersonaHistoryView(
      chapters: ((value['chapters'] as List<dynamic>).map((entry) => PersonaChapterView.fromJson(entry as Map<String, dynamic>)).toList()),
      companionId: value['companion_id'] as String,
      contractVersion: value['contract_version'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'chapters': chapters.map((entry) => entry.toJson()).toList(),
      'companion_id': companionId,
      if (contractVersion != null) 'contract_version': contractVersion,
    };
  }
}

class PersonaRestoreRequest {
  const PersonaRestoreRequest({
    required this.chapterId,
  });

  final String chapterId;

  factory PersonaRestoreRequest.fromJson(Map<String, dynamic> value) {
    return PersonaRestoreRequest(
      chapterId: value['chapter_id'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'chapter_id': chapterId,
    };
  }
}

class PersonaTraitState {
  const PersonaTraitState({
    this.confidence,
    this.lastChangedAt,
    this.source,
    this.value,
  });

  final double? confidence;

  final String? lastChangedAt;

  final String? source;

  final double? value;

  factory PersonaTraitState.fromJson(Map<String, dynamic> value) {
    return PersonaTraitState(
      confidence: value['confidence'] as double?,
      lastChangedAt: value['last_changed_at'] as String?,
      source: value['source'] as String?,
      value: value['value'] as double?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (confidence != null) 'confidence': confidence,
      if (lastChangedAt != null) 'last_changed_at': lastChangedAt,
      if (source != null) 'source': source,
      if (value != null) 'value': value,
    };
  }
}

class RecollectionView {
  const RecollectionView({
    this.rememberedAt,
    this.text,
  });

  final String? rememberedAt;

  final String? text;

  factory RecollectionView.fromJson(Map<String, dynamic> value) {
    return RecollectionView(
      rememberedAt: value['remembered_at'] as String?,
      text: value['text'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (rememberedAt != null) 'remembered_at': rememberedAt,
      if (text != null) 'text': text,
    };
  }
}

class RecollectionsView {
  const RecollectionsView({
    this.contractVersion,
    required this.query,
    required this.recollections,
  });

  final String? contractVersion;

  final String query;

  final List<RecollectionView> recollections;

  factory RecollectionsView.fromJson(Map<String, dynamic> value) {
    return RecollectionsView(
      contractVersion: value['contract_version'] as String?,
      query: value['query'] as String,
      recollections: ((value['recollections'] as List<dynamic>).map((entry) => RecollectionView.fromJson(entry as Map<String, dynamic>)).toList()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      'query': query,
      'recollections': recollections.map((entry) => entry.toJson()).toList(),
    };
  }
}

class Refusal {
  const Refusal({
    this.code,
    required this.kind,
    this.reason,
    this.retryable,
  });

  final String? code;

  final String kind;

  final String? reason;

  final bool? retryable;

  factory Refusal.fromJson(Map<String, dynamic> value) {
    return Refusal(
      code: value['code'] as String?,
      kind: value['kind'] as String,
      reason: value['reason'] as String?,
      retryable: value['retryable'] as bool?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (code != null) 'code': code,
      'kind': kind,
      if (reason != null) 'reason': reason,
      if (retryable != null) 'retryable': retryable,
    };
  }
}

class RenameRequest {
  const RenameRequest({
    required this.displayName,
  });

  final String displayName;

  factory RenameRequest.fromJson(Map<String, dynamic> value) {
    return RenameRequest(
      displayName: value['display_name'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'display_name': displayName,
    };
  }
}

class RevokedSessionsView {
  const RevokedSessionsView({
    this.contractVersion,
    required this.revokedAt,
  });

  final String? contractVersion;

  final String revokedAt;

  factory RevokedSessionsView.fromJson(Map<String, dynamic> value) {
    return RevokedSessionsView(
      contractVersion: value['contract_version'] as String?,
      revokedAt: value['revoked_at'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      'revoked_at': revokedAt,
    };
  }
}

class SpokenMessageView {
  const SpokenMessageView({
    required this.role,
    this.text,
  });

  final String role;

  final String? text;

  factory SpokenMessageView.fromJson(Map<String, dynamic> value) {
    return SpokenMessageView(
      role: value['role'] as String,
      text: value['text'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'role': role,
      if (text != null) 'text': text,
    };
  }
}

class TaskPageView {
  const TaskPageView({
    required this.companionId,
    this.contractVersion,
    this.nextCursor,
    required this.tasks,
  });

  final String companionId;

  final String? contractVersion;

  final String? nextCursor;

  final List<TaskView> tasks;

  factory TaskPageView.fromJson(Map<String, dynamic> value) {
    return TaskPageView(
      companionId: value['companion_id'] as String,
      contractVersion: value['contract_version'] as String?,
      nextCursor: value['next_cursor'] as String?,
      tasks: ((value['tasks'] as List<dynamic>).map((entry) => TaskView.fromJson(entry as Map<String, dynamic>)).toList()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'companion_id': companionId,
      if (contractVersion != null) 'contract_version': contractVersion,
      if (nextCursor != null) 'next_cursor': nextCursor,
      'tasks': tasks.map((entry) => entry.toJson()).toList(),
    };
  }
}

class TaskView {
  const TaskView({
    this.asked,
    this.completedAt,
    this.createdAt,
    this.errorCode,
    this.errorMessage,
    this.expectedOutput,
    this.kind,
    this.progress,
    this.result,
    required this.status,
    required this.taskId,
    this.updatedAt,
    this.urgency,
  });

  final String? asked;

  final String? completedAt;

  final String? createdAt;

  final String? errorCode;

  final String? errorMessage;

  final String? expectedOutput;

  final String? kind;

  final String? progress;

  final String? result;

  final String status;

  final String taskId;

  final String? updatedAt;

  final String? urgency;

  factory TaskView.fromJson(Map<String, dynamic> value) {
    return TaskView(
      asked: value['asked'] as String?,
      completedAt: value['completed_at'] as String?,
      createdAt: value['created_at'] as String?,
      errorCode: value['error_code'] as String?,
      errorMessage: value['error_message'] as String?,
      expectedOutput: value['expected_output'] as String?,
      kind: value['kind'] as String?,
      progress: value['progress'] as String?,
      result: value['result'] as String?,
      status: value['status'] as String,
      taskId: value['task_id'] as String,
      updatedAt: value['updated_at'] as String?,
      urgency: value['urgency'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (asked != null) 'asked': asked,
      if (completedAt != null) 'completed_at': completedAt,
      if (createdAt != null) 'created_at': createdAt,
      if (errorCode != null) 'error_code': errorCode,
      if (errorMessage != null) 'error_message': errorMessage,
      if (expectedOutput != null) 'expected_output': expectedOutput,
      if (kind != null) 'kind': kind,
      if (progress != null) 'progress': progress,
      if (result != null) 'result': result,
      'status': status,
      'task_id': taskId,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (urgency != null) 'urgency': urgency,
    };
  }
}

class TranscriptTurnView {
  const TranscriptTurnView({
    this.finishedAt,
    required this.messages,
    this.startedAt,
    this.status,
    required this.turnId,
  });

  final String? finishedAt;

  final List<SpokenMessageView> messages;

  final String? startedAt;

  final String? status;

  final String turnId;

  factory TranscriptTurnView.fromJson(Map<String, dynamic> value) {
    return TranscriptTurnView(
      finishedAt: value['finished_at'] as String?,
      messages: ((value['messages'] as List<dynamic>).map((entry) => SpokenMessageView.fromJson(entry as Map<String, dynamic>)).toList()),
      startedAt: value['started_at'] as String?,
      status: value['status'] as String?,
      turnId: value['turn_id'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (finishedAt != null) 'finished_at': finishedAt,
      'messages': messages.map((entry) => entry.toJson()).toList(),
      if (startedAt != null) 'started_at': startedAt,
      if (status != null) 'status': status,
      'turn_id': turnId,
    };
  }
}

class TranscriptView {
  const TranscriptView({
    this.contractVersion,
    required this.conversationId,
    this.nextCursor,
    required this.turns,
  });

  final String? contractVersion;

  final String conversationId;

  final String? nextCursor;

  final List<TranscriptTurnView> turns;

  factory TranscriptView.fromJson(Map<String, dynamic> value) {
    return TranscriptView(
      contractVersion: value['contract_version'] as String?,
      conversationId: value['conversation_id'] as String,
      nextCursor: value['next_cursor'] as String?,
      turns: ((value['turns'] as List<dynamic>).map((entry) => TranscriptTurnView.fromJson(entry as Map<String, dynamic>)).toList()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (contractVersion != null) 'contract_version': contractVersion,
      'conversation_id': conversationId,
      if (nextCursor != null) 'next_cursor': nextCursor,
      'turns': turns.map((entry) => entry.toJson()).toList(),
    };
  }
}

class VitalView {
  const VitalView({
    this.concern,
    required this.name,
    required this.reading,
    this.unavailableReason,
  });

  final String? concern;

  final String name;

  final String reading;

  final String? unavailableReason;

  factory VitalView.fromJson(Map<String, dynamic> value) {
    return VitalView(
      concern: value['concern'] as String?,
      name: value['name'] as String,
      reading: value['reading'] as String,
      unavailableReason: value['unavailable_reason'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (concern != null) 'concern': concern,
      'name': name,
      'reading': reading,
      if (unavailableReason != null) 'unavailable_reason': unavailableReason,
    };
  }
}
