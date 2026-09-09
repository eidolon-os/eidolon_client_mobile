import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../controller/client_controller.dart';
import '../../generated/device_foundation_v1.dart';
import '../../generated/management_v1.dart';
import '../../platform/platform_bridge.dart';
import '../../services/eidolon_session.dart';
import '../device_management/mounted_device_models.dart';
import '../device_setup/admission_projection.dart';
import '../device_setup/device_setup_models.dart';
import '../device_setup/device_setup_ports.dart';
import '../device_setup/enrollment_decision_id.dart';
import '../device_setup/mobile_body_enrollment_session.dart';
import 'conversation_provisioner.dart';

/// Management capabilities belong to the Controller half of the App. The
/// device provisioner and audio session never receive the binding capability.
class ConversationManagement {
  const ConversationManagement(
      {required this.controllerId,
      required this.admission,
      required this.roster,
      required this.device,
      required this.assign});
  final String controllerId;
  final DeviceAdmissionPort admission;
  final Future<CompanionRosterView> Function({String? cursor}) roster;
  final Future<MountedDevice?> Function(String deviceId) device;
  final Future<void> Function(
      {required String deviceId,
      required String requestId,
      required String? companionId,
      required int expectedRevision}) assign;
}

/// Per-page user intent. Enrollment itself outlives this object in the App's
/// device scope; no management write happens from a listener or a poll.
class ConversationFlow extends ChangeNotifier {
  ConversationFlow(
      {required this.hostName,
      required this.ownerDomainId,
      required this.loadTarget,
      required this.enrollment,
      required this.management,
      required ConversationProvisioner provisioner,
      PlatformBridge? platform,
      EidolonSession? session})
      : client = ClientController(
            conversationProvisioner: provisioner,
            enrollment: enrollment,
            platform: platform,
            session: session) {
    client.addListener(_changed);
  }
  final String hostName;
  final String ownerDomainId;
  final Future<DeviceOnboardingTarget> Function() loadTarget;
  final MobileBodyEnrollmentSession enrollment;
  final ConversationManagement management;
  final ClientController client;
  List<CompanionSummaryView> companions = [];
  MountedDevice? device;
  EnrollmentRecoveryProjectionV1? reviewedProposal;
  String? selectedCompanionId;
  String? error;
  String? managementError;
  bool busy = false;
  bool _disposed = false;
  bool _closing = false;
  String? _decisionCompanion;
  bool _startWhenReady = false;
  bool _continuing = false;
  bool _loadingReview = false;
  ({
    String deviceId,
    String companionId,
    int revision,
    String commandId
  })? _assignment;

  String get companionName {
    final selected = companions
        .where((c) => c.companionId == selectedCompanionId)
        .firstOrNull;
    if (selected != null) return selected.displayName ?? selected.companionId;
    if (device?.attachedCompanionId == selectedCompanionId) {
      return device?.attachedCompanionName.isNotEmpty == true
          ? device!.attachedCompanionName
          : selectedCompanionId ?? '选择伙伴';
    }
    return selectedCompanionId ?? '选择伙伴';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _changed() {
    if (_disposed || _closing) return;
    _notify();
    if (client.enrollmentAct == MobileBodyEnrollmentAct.approve &&
        reviewedProposal == null &&
        !_loadingReview) {
      unawaited(loadReview());
    }
    if (_startWhenReady &&
        !client.isBusy &&
        client.canJoin &&
        !_continuing &&
        !busy) {
      _continuing = true;
      _startWhenReady = false;
      unawaited(_continueConversation());
    }
  }

  Future<void> initialize() async {
    // Read-only management data may fail independently of the Device channel.
    await Future.wait([client.start(), refreshManagement()]);
    if (device == null && client.identity != null && !_disposed) {
      try {
        device = await management.device(client.identity!.deviceInstanceId);
        selectedCompanionId ??= device?.attachedCompanionId;
      } catch (e) {
        managementError = _message(e);
      }
      _notify();
    }
  }

  Future<void> refreshManagement() async {
    try {
      final loaded = <CompanionSummaryView>[];
      String? cursor;
      do {
        final page = await management.roster(cursor: cursor);
        loaded
            .addAll(page.companions.where((c) => c.lifecycleState == 'active'));
        cursor = page.nextCursor;
      } while (cursor != null);
      if (_disposed) return;
      companions = loaded;
      final identity = client.identity;
      if (identity != null) {
        device = await management.device(identity.deviceInstanceId);
        if (device?.attachedCompanionId != null) {
          selectedCompanionId = device!.attachedCompanionId;
        }
      }
      managementError = null;
    } catch (e) {
      managementError = '暂时无法读取伙伴或本机绑定。${_message(e)}';
    }
    _notify();
  }

  Future<void> loadReview() async {
    final pending = enrollment.pending;
    final identity = client.identity;
    if (pending == null || identity == null || _loadingReview) return;
    _loadingReview = true;
    try {
      final target = await loadTarget();
      final projection = await management.admission
          .recover(enrollmentId: pending.enrollmentId);
      projection.validateForOwner(ownerDomainId,
          ownerDomainGeneration:
              target.ownerDomainDescriptor.ownerDomainGeneration);
      final p = projection.proposal.json;
      if (p['device_instance_candidate_id'] != identity.deviceInstanceId ||
          p['enrollment_id'] != pending.enrollmentId ||
          p['proposal_revision'] != pending.proposalRevision ||
          p['handoff_key_id'] != pending.handoffKeyId) {
        throw const FormatException('本机提案与待批准记录不一致');
      }
      reviewedProposal = projection;
      error = null;
    } catch (e) {
      error = _message(e);
    } finally {
      _loadingReview = false;
      _notify();
    }
  }

  Future<void> propose() => _run(() async {
        reviewedProposal = null;
        await client.proposeSelf();
        await loadReview();
      });

  Future<void> approveAndStart() => _run(() async {
        final projection = reviewedProposal;
        if (projection == null || selectedCompanionId == null) {
          throw StateError('请先核对本机提案并选择应答伙伴');
        }
        final pending = enrollment.pending;
        if (pending == null ||
            !await enrollment.canFinish() ||
            projection.proposal.json['enrollment_id'] != pending.enrollmentId ||
            projection.proposalRevision != pending.proposalRevision) {
          throw StateError('登记已变化，请重新核对本机提案');
        }
        _decisionCompanion ??= selectedCompanionId;
        // This is the only approval call, entered from an explicit user action.
        await management.admission.decide(
            requestId: enrollmentDecisionId(
                ownerDomainId: ownerDomainId,
                controllerId: management.controllerId,
                projection: projection),
            projection: projection,
            initialCompanionId: _decisionCompanion);
        _decisionCompanion = null;
        reviewedProposal = null;
        _startWhenReady = true;
        await client.checkActivation();
      });

  Future<void> choose(String companionId, {bool restart = false}) =>
      _run(() async {
        if (_decisionCompanion != null && _decisionCompanion != companionId) {
          throw StateError('上次确认结果尚未收到，请先重新检查或重试确认，再更换伙伴');
        }
        if (!companions.any((c) => c.companionId == companionId)) {
          throw StateError('这位伙伴目前不可选，请刷新伙伴列表');
        }
        if (companionId == selectedCompanionId &&
            !restart &&
            _assignment == null) {
          return;
        }
        if (client.enrollmentAct == MobileBodyEnrollmentAct.propose ||
            client.enrollmentAct == MobileBodyEnrollmentAct.approve) {
          selectedCompanionId = companionId;
          return;
        }
        final identity = client.identity;
        final current = identity == null
            ? null
            : await management.device(identity.deviceInstanceId);
        if (current == null) {
          if (client.canJoin || client.canLeave) {
            throw StateError('暂未读到本机挂载，请稍后重试');
          }
          selectedCompanionId = companionId;
          return;
        }
        _startWhenReady = false;
        if (client.canLeave) await client.leave();
        if (current.attachedCompanionId != companionId) {
          var attempt = _assignment;
          if (attempt == null ||
              attempt.deviceId != current.deviceId ||
              attempt.companionId != companionId ||
              attempt.revision != current.revision) {
            attempt = (
              deviceId: current.deviceId,
              companionId: companionId,
              revision: current.revision,
              commandId: 'body-choice-${DateTime.now().microsecondsSinceEpoch}'
            );
            _assignment = attempt;
          }
          await management.assign(
              deviceId: attempt.deviceId,
              requestId: attempt.commandId,
              companionId: attempt.companionId,
              expectedRevision: attempt.revision);
        }
        device = await management.device(current.deviceId);
        selectedCompanionId = device?.attachedCompanionId;
        if (selectedCompanionId != companionId) {
          throw StateError('主机尚未确认这次伙伴选择，请重新读取本机绑定');
        }
        _assignment = null;
        if (restart) _startWhenReady = true;
      });

  Future<void> startConversation() => _run(() async {
        _startWhenReady = true;
        if (client.canLeave) await client.leave();
        if (!client.canJoin) await client.retry();
      });

  Future<void> _continueConversation() async {
    try {
      try {
        final identity = client.identity;
        if (identity != null) {
          device = await management
              .device(identity.deviceInstanceId)
              .timeout(const Duration(seconds: 3));
          selectedCompanionId =
              device?.attachedCompanionId ?? selectedCompanionId;
        }
      } catch (_) {
        // Controller availability does not decide Device authorization.
        device = null;
      }
      // Assignment is management projection, not a prerequisite to an already
      // authorized Device opening a session. A confirmed empty assignment is
      // actionable; unavailable management data is not proof of an empty one.
      if (device != null && device!.attachedCompanionId == null) {
        throw StateError('请先为本机选择应答伙伴');
      }
      if (!_disposed && !_closing) await client.join();
    } catch (e) {
      error = _message(e);
    } finally {
      _continuing = false;
      _notify();
    }
  }

  Future<void> retry() => _run(() async {
        await client.retry();
        if (client.enrollmentAct != MobileBodyEnrollmentAct.approve) {
          _decisionCompanion = null;
        }
        await refreshManagement();
      });

  Future<void> _run(Future<void> Function() action) async {
    if (busy || _disposed || _closing) return;
    busy = true;
    error = null;
    _notify();
    try {
      await action();
    } catch (e) {
      _startWhenReady = false;
      error = _message(e);
    } finally {
      busy = false;
      _changed();
    }
  }

  static String _message(Object e) => e
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('FormatException: ', '');

  Future<void> close() async {
    _closing = true;
    _startWhenReady = false;
    await client.leave();
  }

  @override
  void dispose() {
    _disposed = true;
    _startWhenReady = false;
    client.removeListener(_changed);
    client.dispose();
    super.dispose();
  }
}
