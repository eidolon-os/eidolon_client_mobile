import 'package:flutter/material.dart';

import 'controller_grant_models.dart';

/// The phones that manage one Host.
///
/// The Host has been able to answer all three of these questions for a while —
/// who holds me, let one more in, withdraw one — and the App said the protocol
/// did not exist yet. It did. A household with one phone and no way to add a
/// second is one dropped phone away from a Host nobody can manage.
class ManagedControllersPage extends StatefulWidget {
  const ManagedControllersPage({
    super.key,
    required this.thisControllerId,
    required this.loadControllers,
    required this.invite,
    required this.revoke,
  });

  /// The phone this App runs on, so it is never offered as "some other phone".
  final String thisControllerId;
  final Future<List<ControllerGrant>> Function() loadControllers;
  final Future<ControllerInvitation> Function() invite;
  final Future<void> Function(String controllerId) revoke;

  @override
  State<ManagedControllersPage> createState() => _ManagedControllersPageState();
}

class _ManagedControllersPageState extends State<ManagedControllersPage> {
  List<ControllerGrant>? _controllers;
  ControllerInvitation? _invitation;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final controllers = await widget.loadControllers();
      if (!mounted) return;
      setState(() => _controllers = controllers);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _invite() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final invitation = await widget.invite();
      if (!mounted) return;
      setState(() => _invitation = invitation);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRevoke(ControllerGrant grant) async {
    final itself = grant.controllerId == widget.thisControllerId;
    final remaining = (_controllers?.length ?? 1) - 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('confirm-controller-revocation'),
        title: Text(itself ? '撤销这台手机？' : '撤销 ${grant.displayName}？'),
        content: Text(
          itself
              // Losing your own authority is a different act from removing
              // someone else's, and the difference is worth a sentence: after
              // this, this phone manages nothing.
              ? '这台手机将立即失去管理这台主机的权限。'
                  '${remaining > 0 ? '其他手机不受影响，可以由它们重新邀请你。' : '之后没有任何手机能管理它，只能由主机旁的人做一次恢复。'}'
              : '这台手机会立即失去管理权限。主机上的 Owner、设备和数据都不受影响；'
                  '之后可以重新邀请它。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-controller-revocation-action'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.revoke(grant.controllerId);
      if (!mounted) return;
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controllers = _controllers;
    return Scaffold(
      key: const Key('managed-controllers-page'),
      appBar: AppBar(
        title: const Text('管理手机'),
        actions: [
          IconButton(
            key: const Key('refresh-controllers'),
            onPressed: _busy ? null : _load,
            tooltip: '刷新',
            icon: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.phonelink_lock_outlined),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '这些手机可以管理这台主机。添加一台由已经在这里的手机发起，'
                      '主机不会自己决定谁能加入。',
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 16),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(error, key: const Key('controllers-error')),
              ),
            ),
          ],
          if (_invitation case final invitation?) ...[
            const SizedBox(height: 16),
            Card(
              key: const Key('controller-invitation'),
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '在另一台手机上打开 Eidolon，选择这台主机，输入：',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 10),
                    SelectableText(
                      invitation.setupCode,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '这个码只能用一次，'
                      '${invitation.expiresAt.toLocal().toString().substring(0, 16)} 之前有效。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          // A refusal is an answer. Leaving the spinner beside it would say
          // the Host is still being asked, which it is not.
          if (controllers == null && _error != null)
            const SizedBox.shrink()
          else if (controllers == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              ),
            )
          else if (controllers.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  '主机没有报告任何管理手机。',
                  key: Key('controllers-empty'),
                ),
              ),
            )
          else
            ...controllers.map(
              (grant) => _ControllerCard(
                grant: grant,
                isThisPhone: grant.controllerId == widget.thisControllerId,
                onRevoke: _busy ? null : () => _confirmRevoke(grant),
              ),
            ),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('invite-controller'),
            onPressed: _busy ? null : _invite,
            icon: const Icon(Icons.add),
            label: const Text('添加一台手机'),
          ),
        ],
      ),
    );
  }
}

class _ControllerCard extends StatelessWidget {
  const _ControllerCard({
    required this.grant,
    required this.isThisPhone,
    required this.onRevoke,
  });

  final ControllerGrant grant;
  final bool isThisPhone;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          key: Key('controller-${grant.controllerId}'),
          contentPadding: const EdgeInsets.all(16),
          leading: Icon(
            isThisPhone ? Icons.smartphone : Icons.phone_iphone_outlined,
            color: isThisPhone ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Row(
            children: [
              Flexible(child: Text(grant.displayName)),
              if (isThisPhone) ...[
                const SizedBox(width: 8),
                const Chip(label: Text('这台手机')),
              ],
            ],
          ),
          subtitle: Text(
            '${grant.platform} · 认领于 '
            '${grant.createdAt.toLocal().toString().substring(0, 16)}',
          ),
          trailing: IconButton(
            key: Key('revoke-${grant.controllerId}'),
            onPressed: onRevoke,
            tooltip: '撤销管理权限',
            icon: Icon(
              Icons.link_off,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      );
}
