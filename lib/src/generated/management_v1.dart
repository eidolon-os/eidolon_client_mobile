// Generated from eidolon_admin/contracts/management/v1/management-v1.openapi.json.
// Do not edit by hand; contracts/management/v1/generate_dart.py owns this file
// and a test runs it with --check, so an edit here fails rather than surviving.
//
// No operation takes an ownerId: the Owner comes from the authenticated
// Controller session, so it is not expressible from a client.

/// The paths this contract describes, so a caller does not spell one.
class ManagementV1 {
  const ManagementV1._();

  static const String companionsPath = '/api/management/v1/companions';
  static String companionsByCompanionIdPath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}';
  static String companionsByCompanionIdConversationsPath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/conversations';
  static String companionsByCompanionIdConversationsByConversationIdTurnsPath(String companionId, String conversationId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/conversations/${Uri.encodeComponent(conversationId)}/turns';
  static String companionsByCompanionIdFacePath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/face';
  static String companionsByCompanionIdFaceStatePath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/face-state';
  static String companionsByCompanionIdLifecyclePath(String companionId) => '/api/management/v1/companions/${Uri.encodeComponent(companionId)}/lifecycle';
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
  static const String hostServicesPath = '/api/management/v1/host/services';
  static String hostServicesByServiceIdByOperationPath(String serviceId, String operation) => '/api/management/v1/host/services/${Uri.encodeComponent(serviceId)}/${Uri.encodeComponent(operation)}';
  static const String hostVitalsPath = '/api/management/v1/host/vitals';
  static const String memoryEntriesPath = '/api/management/v1/memory/entries';
  static String memoryEntriesByEntryIdAudiencePath(String entryId) => '/api/management/v1/memory/entries/${Uri.encodeComponent(entryId)}/audience';
  static const String memoryExportPath = '/api/management/v1/memory/export';
  static const String memoryForgetConfirmPath = '/api/management/v1/memory/forget/confirm';
  static const String memoryForgetPreviewPath = '/api/management/v1/memory/forget/preview';
  static const String memoryLibraryPath = '/api/management/v1/memory/library';
  static const String memoryRecollectionsPath = '/api/management/v1/memory/recollections';
  static const String ownerPath = '/api/management/v1/owner';
  static const String ownerActionsRevokeRuntimeSessionsPath = '/api/management/v1/owner/actions/revoke-runtime-sessions';
  static const String ownerDefaultCompanionPath = '/api/management/v1/owner/default-companion';
}

class CompanionCreateRequest {
  const CompanionCreateRequest({
    required this.displayName,
    this.kind,
    required this.operationId,
  });

  final String displayName;

  final String? kind;

  final String operationId;

  factory CompanionCreateRequest.fromJson(Map<String, dynamic> value) {
    return CompanionCreateRequest(
      displayName: value['display_name'] as String,
      kind: value['kind'] as String?,
      operationId: value['operation_id'] as String,
    );
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
}

class CompanionDetailView {
  const CompanionDetailView({
    required this.companionId,
    this.contractVersion,
    this.displayName,
    required this.isDefault,
    required this.kind,
    required this.lifecycleState,
    required this.revision,
  });

  final String companionId;

  final String? contractVersion;

  final String? displayName;

  final bool isDefault;

  final String kind;

  final String lifecycleState;

  final int revision;

  factory CompanionDetailView.fromJson(Map<String, dynamic> value) {
    return CompanionDetailView(
      companionId: value['companion_id'] as String,
      contractVersion: value['contract_version'] as String?,
      displayName: value['display_name'] as String?,
      isDefault: value['is_default'] as bool,
      kind: value['kind'] as String,
      lifecycleState: value['lifecycle_state'] as String,
      revision: value['revision'] as int,
    );
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
}

class CompanionLifecycleView {
  const CompanionLifecycleView({
    required this.companionId,
    this.contractVersion,
    this.defaultCompanionId,
    required this.lifecycleState,
    required this.revision,
  });

  final String companionId;

  final String? contractVersion;

  final String? defaultCompanionId;

  final String lifecycleState;

  final int revision;

  factory CompanionLifecycleView.fromJson(Map<String, dynamic> value) {
    return CompanionLifecycleView(
      companionId: value['companion_id'] as String,
      contractVersion: value['contract_version'] as String?,
      defaultCompanionId: value['default_companion_id'] as String?,
      lifecycleState: value['lifecycle_state'] as String,
      revision: value['revision'] as int,
    );
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
}

class CompanionRosterView {
  const CompanionRosterView({
    required this.companions,
    this.contractVersion,
    this.defaultCompanionId,
    this.nextCursor,
  });

  final List<CompanionSummaryView> companions;

  final String? contractVersion;

  final String? defaultCompanionId;

  final String? nextCursor;

  factory CompanionRosterView.fromJson(Map<String, dynamic> value) {
    return CompanionRosterView(
      companions: ((value['companions'] as List<dynamic>).map((entry) => CompanionSummaryView.fromJson(entry as Map<String, dynamic>)).toList()),
      contractVersion: value['contract_version'] as String?,
      defaultCompanionId: value['default_companion_id'] as String?,
      nextCursor: value['next_cursor'] as String?,
    );
  }
}

class CompanionSummaryView {
  const CompanionSummaryView({
    required this.companionId,
    required this.createdAt,
    this.displayName,
    required this.kind,
    required this.lifecycleState,
    required this.revision,
    required this.updatedAt,
  });

  final String companionId;

  final String createdAt;

  final String? displayName;

  final String kind;

  final String lifecycleState;

  final int revision;

  final String updatedAt;

  factory CompanionSummaryView.fromJson(Map<String, dynamic> value) {
    return CompanionSummaryView(
      companionId: value['companion_id'] as String,
      createdAt: value['created_at'] as String,
      displayName: value['display_name'] as String?,
      kind: value['kind'] as String,
      lifecycleState: value['lifecycle_state'] as String,
      revision: value['revision'] as int,
      updatedAt: value['updated_at'] as String,
    );
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
}

class HTTPValidationError {
  const HTTPValidationError({
    this.detail,
  });

  final List<ValidationError>? detail;

  factory HTTPValidationError.fromJson(Map<String, dynamic> value) {
    return HTTPValidationError(
      detail: value['detail'] == null ? null : ((value['detail'] as List<dynamic>).map((entry) => ValidationError.fromJson(entry as Map<String, dynamic>)).toList()),
    );
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
}

class ManagementContextView {
  const ManagementContextView({
    required this.capabilities,
    this.contractVersion,
    this.defaultCompanionId,
    required this.limits,
    required this.owner,
  });

  final Map<String, bool> capabilities;

  final String? contractVersion;

  final String? defaultCompanionId;

  final Map<String, int?> limits;

  final OwnerContextView owner;

  factory ManagementContextView.fromJson(Map<String, dynamic> value) {
    return ManagementContextView(
      capabilities: ((value['capabilities'] as Map<String, dynamic>).map((key, entry) => MapEntry(key, entry as bool))),
      contractVersion: value['contract_version'] as String?,
      defaultCompanionId: value['default_companion_id'] as String?,
      limits: ((value['limits'] as Map<String, dynamic>).map((key, entry) => MapEntry(key, entry as int?))),
      owner: OwnerContextView.fromJson(value['owner'] as Map<String, dynamic>),
    );
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
}

class ValidationError {
  const ValidationError({
    this.ctx,
    this.input,
    required this.loc,
    required this.msg,
    required this.type,
  });

  final Map<String, Object?>? ctx;

  final Object? input;

  final List<Object> loc;

  final String msg;

  final String type;

  factory ValidationError.fromJson(Map<String, dynamic> value) {
    return ValidationError(
      ctx: value['ctx'] == null ? null : ((value['ctx'] as Map<String, dynamic>).map((key, entry) => MapEntry(key, entry as Object?))),
      input: value['input'],
      loc: ((value['loc'] as List<dynamic>).map((entry) => entry as Object).toList()),
      msg: value['msg'] as String,
      type: value['type'] as String,
    );
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
}
