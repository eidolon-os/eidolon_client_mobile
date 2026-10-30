import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../generated/management_v1.dart';
import '../../management/management_client.dart';

/// Host-owned state survives navigation; only confirmed closure releases it.
class RoleGroupController extends ChangeNotifier {
  RoleGroupController({required this.savedCommand, this.loadSavedRuns});
  final Future<TeamStarts> Function(String teamId)? loadSavedRuns;
  final Future<RoleGroupStatus> Function(
          String action, String sessionId, String teamId, int revision)
      savedCommand;
  String? teamId;
  int? teamRevision;

  Future<void> startSaved(TeamRevision team) async {
    if (_disposed || busy || sessionId != null) return;
    teamId = team.teamId;
    teamRevision = team.revision;
    sessionId =
        'team-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
    await _invoke('open');
  }

  String? sessionId;
  String state = 'closed';
  String? notice;
  bool busy = false;
  bool closeRequested = false;
  bool closeUnconfirmed = false;
  Timer? _poll;
  bool _disposed = false;
  Completer<void>? _pendingClose;

  Future<void> close() {
    if (_disposed || sessionId == null) return Future.value();
    if (!busy) return _invoke('close');
    if (closeRequested && !closeUnconfirmed) {
      return _pendingClose?.future ?? Future.value();
    }
    // Serialize a user's close intent after the in-flight request. Polling must
    // never consume an explicit command, nor race its response with a close.
    final pending = _pendingClose ??= Completer<void>();
    closeRequested = true;
    closeUnconfirmed = false;
    notice = '正在停止播放并结束团队…';
    notifyListeners();
    return pending.future;
  }

  Future<void> refresh() => _invoke('status');

  /// Reconcile a persisted session identity without replaying its open command.
  /// The Host remains authoritative even if the previous app process died
  /// before receiving the start or close response.
  Future<void> restoreSaved(TeamStartRecord run) async {
    if (_disposed || busy || sessionId != null || run.closed) return;
    teamId = run.teamId;
    teamRevision = run.revision;
    await _restore(run.sessionId);
  }

  Future<void> _restore(String id) async {
    if (_disposed || busy || sessionId != null) return;
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id');
    sessionId = id;
    state = 'preparing';
    notice = '正在确认上次团队状态…';
    await refresh();
  }

  Future<void> _invoke(String action) async {
    final id = sessionId;
    if (id == null || busy || _disposed) return;
    _poll?.cancel();
    busy = true;
    if (action == 'close') {
      closeRequested = true;
      closeUnconfirmed = false;
      notice = '正在停止播放并结束团队…';
    }
    notifyListeners();
    try {
      final result = await savedCommand(action, id, teamId!, teamRevision!);
      if (_disposed || sessionId != id) return;
      if (result.sessionId != id || result.scenario != 'ip_role_group') {
        throw StateError('Unexpected team response');
      }
      state = result.state;
      if (closeRequested && state == 'failed') closeUnconfirmed = true;
      notice = _pendingClose != null && state != 'closed'
          ? '正在停止播放并结束团队…'
          : closeRequested && closeUnconfirmed && state != 'closed'
              ? '结束尚未确认，请重试结束；确认前不能开始新团队。'
              : switch (state) {
                  'preparing' => '正在让所选设备进入团队…',
                  'ready' => (result.roundError ?? '').isNotEmpty
                      ? '上一轮没能回答，团队仍在运行。请按住说话设备再试一次。'
                      : '团队已就绪。按住 PTT 说话，可点名、追问或让成员讨论；再次按下即可打断。',
                  'closing' => '正在停止播放并结束团队…',
                  'closed' => (result.error ?? '').trim().isEmpty
                      ? '团队已结束，可使用原来的单聊。'
                      : '${_failureReason(result.error!)}。设备已退出，可重新开始。',
                  'failed' => (result.error ?? '').trim().isEmpty
                      ? '团队未能继续，请结束团队后重试。'
                      : '${_failureReason(result.error!)}。请结束团队后重试。',
                  _ => '正在确认团队状态…',
                };
      if (state == 'closed') {
        sessionId = null;
        teamId = null;
        teamRevision = null;
        closeRequested = false;
        closeUnconfirmed = false;
      }
    } catch (error) {
      if (!_disposed) {
        // A definite refusal can precede Data accepting this identity (for
        // example another phone started first). Reconcile the authoritative
        // active list instead of polling a nonexistent run forever. A lost
        // response or failed reconciliation must still retain the identity.
        if (action == 'open' &&
            teamId != null &&
            loadSavedRuns != null &&
            error is ManagementRequestException &&
            const {400, 403, 404, 409, 422}.contains(error.statusCode)) {
          try {
            final active = (await loadSavedRuns!(teamId!))
                .starts
                .where((run) => !run.closed)
                .toList();
            if (!_disposed &&
                sessionId == id &&
                !active.any((run) => run.sessionId == id) &&
                active.length <= 1) {
              // A queued cancellation targets this attempt, never another
              // phone's run discovered while reconciling its refusal.
              final restoreExisting = active.isNotEmpty && !closeRequested;
              sessionId = restoreExisting ? active.single.sessionId : null;
              teamRevision = restoreExisting ? active.single.revision : null;
              state = restoreExisting ? 'preparing' : 'closed';
              notice = !restoreExisting
                  ? '未能开始聊天，伙伴或设备可能被占用，或配置已变化。请确认后刷新团队再试。'
                  : '团队已有聊天，正在确认现有运行。';
              if (!restoreExisting) {
                teamId = null;
                closeRequested = false;
                closeUnconfirmed = false;
              }
              return;
            }
          } catch (_) {
            // Keep the uncertain run until authoritative reconciliation works.
          }
        }
        if (closeRequested) {
          closeUnconfirmed = true;
          notice = '结束尚未确认，请重试结束；确认前不能开始新团队。';
        } else {
          notice = '无法确认团队状态，请刷新或结束团队；不会自动重新启动。';
        }
      }
    } finally {
      busy = false;
      final pendingClose = _pendingClose;
      _pendingClose = null;
      if (!_disposed) {
        notifyListeners();
        if (pendingClose != null) {
          try {
            await _invoke('close');
          } finally {
            pendingClose.complete();
          }
        } else if (sessionId != null) {
          _poll = Timer(const Duration(seconds: 2), refresh);
        }
      } else {
        pendingClose?.complete();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    super.dispose();
  }

  String _failureReason(String code) => switch (code) {
        'TEAM_WORKER_DISCONNECTED' => '主机对话服务中断，团队已停止',
        'TEAM_START_REFUSED' => '伙伴、设备或当前配置暂不可用，未能开始团队聊天',
        'TEAM_DEVICE_DISCONNECTED' ||
        'ENDPOINT_REACHABILITY_LOST' =>
          '团队设备连接中断',
        _ => '团队运行遇到问题',
      };
}
