import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../generated/management_v1.dart';

typedef RoleGroupCommand = Future<RoleGroupStatus> Function(
    String action, String sessionId, RoleGroupStart? selection);

/// Host-owned state survives navigation; only explicit close ends the team.
class RoleGroupController extends ChangeNotifier {
  RoleGroupController(this.command);
  final RoleGroupCommand command;
  String? sessionId;
  String state = 'closed';
  String? notice;
  bool busy = false;
  bool closeRequested = false;
  bool closeUnconfirmed = false;
  RoleGroupStart? selection;
  Timer? _poll;
  bool _disposed = false;

  Future<void> start(String input, List<String> outputs,
      {Map<String, String> roles = const {},
      Map<String, String> descriptions = const {},
      String goal = '',
      int replyBudget = 8}) async {
    if (sessionId != null || busy) return;
    sessionId =
        'team-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
    selection = RoleGroupStart(
        sessionId: sessionId!,
        inputDeviceId: input,
        outputDeviceIds: List.unmodifiable(outputs),
        roles: [
          for (final output in outputs)
            if ((roles[output] ?? '').trim().isNotEmpty)
              RoleGroupAssignment(
                  outputDeviceId: output,
                  role: SceneRole(
                      name: roles[output]!.trim(),
                      description: (descriptions[output] ?? '').trim()))
        ],
        goal: goal.trim(),
        replyBudget: replyBudget);
    await _invoke('open');
  }

  Future<void> close() => _invoke('close');
  Future<void> refresh() => _invoke('status');

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
      final result =
          await command(action, id, action == 'open' ? selection : null);
      if (_disposed || sessionId != id) return;
      if (result.sessionId != id || result.scenario != 'ip_role_group') {
        throw StateError('Unexpected team response');
      }
      state = result.state;
      if (closeRequested && state == 'failed') closeUnconfirmed = true;
      notice = closeRequested && closeUnconfirmed && state != 'closed'
          ? '结束尚未确认，请重试结束；确认前不能开始新团队。'
          : switch (state) {
              'preparing' => '正在让所选设备进入团队…',
              'ready' => '团队已就绪。按住 PTT 说话，可点名、追问或让成员讨论；再次按下即可打断。',
              'closing' => '正在停止播放并结束团队…',
              'closed' => '团队已结束，可使用原来的单聊。',
              'failed' => '团队未能继续，请结束团队后重试。',
              _ => '正在确认团队状态…',
            };
      if (state == 'closed') {
        sessionId = null;
        selection = null;
        closeRequested = false;
        closeUnconfirmed = false;
      }
    } catch (_) {
      if (!_disposed) {
        if (closeRequested) {
          closeUnconfirmed = true;
          notice = '结束尚未确认，请重试结束；确认前不能开始新团队。';
        } else {
          notice = '无法确认团队状态，请刷新或结束团队；不会自动重新启动。';
        }
      }
    } finally {
      busy = false;
      if (!_disposed) {
        notifyListeners();
        if (sessionId != null) {
          _poll = Timer(const Duration(seconds: 2), refresh);
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    super.dispose();
  }
}
