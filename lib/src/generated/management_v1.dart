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
  static const String contextPath = '/api/management/v1/context';
  static const String memoryForgetConfirmPath = '/api/management/v1/memory/forget/confirm';
  static const String memoryForgetPreviewPath = '/api/management/v1/memory/forget/preview';
  static const String memoryLibraryPath = '/api/management/v1/memory/library';
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
