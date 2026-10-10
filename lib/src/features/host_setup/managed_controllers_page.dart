import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';

class ManagedControllersPage extends StatefulWidget {
  const ManagedControllersPage({
    super.key,
    required this.loadControllers,
    required this.revoke,
  });

  /// Which phone is which is the Host's answer now: every row says whether it
  /// is the one asking, computed from the session that asked. This page used to
  /// compare identifiers itself, which is a second place to be wrong about the
  /// phone a person is holding while they decide which one to sign out.
  final Future<List<ControllerView>> Function() loadControllers;
  final Future<void> Function(String controllerId) revoke;

  @override
  State<ManagedControllersPage> createState() => _ManagedControllersPageState();
}

class _ManagedControllersPageState extends State<ManagedControllersPage> {
  List<ControllerView>? _controllers;
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

  Future<void> _confirmRevoke(ControllerView grant) async {
    final itself = grant.isYou;
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
                  '${remaining > 0 ? '其他手机不受影响。之后可搜索主机，使用主机提供的 Setup 码重新获得授权。' : '这是最后一台管理手机，主机会拒绝撤销。'}'
              : '这台手机会立即失去管理权限。主机上的 Owner、设备和数据都不受影响；'
                  '之后可在该手机上搜索主机，使用主机提供的 Setup 码重新获得授权。',
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
                      '每台手机都是平等的管理端。其他手机也可以独立搜索这台主机，'
                      '使用主机提供的 Setup 码获得管理授权。',
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
                isThisPhone: grant.isYou,
                onRevoke: _busy ? null : () => _confirmRevoke(grant),
              ),
            ),
        ],
      ),
    );
  }
}

/// A phone that never said what it is called still has to be pickable out of a
/// list, so it is shown by the short end of its identifier rather than by an
/// empty line.
String _name(ControllerView grant) => (grant.displayName ?? '').isNotEmpty
    ? grant.displayName!
    : '未命名的手机 ${grant.controllerId.split('-').last}';

/// When it claimed this Host, in local time — and only if the Host sent a
/// moment this app can actually read. A timestamp it cannot parse is left out
/// rather than shown raw: a person reading a screen has no use for an
/// unparseable string, and cropping one produces a lie.
String _claimed(ControllerView grant) {
  final platform = (grant.platform ?? '').isNotEmpty ? grant.platform! : '未知设备';
  final claimed = DateTime.tryParse(grant.claimedAt);
  if (claimed == null) return platform;
  return '$platform · 认领于 '
      '${claimed.toLocal().toString().substring(0, 16)}';
}

class _ControllerCard extends StatelessWidget {
  const _ControllerCard({
    required this.grant,
    required this.isThisPhone,
    required this.onRevoke,
  });

  final ControllerView grant;
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
              Flexible(child: Text(_name(grant))),
              if (isThisPhone) ...[
                const SizedBox(width: 8),
                const Chip(label: Text('这台手机')),
              ],
            ],
          ),
          subtitle: Text(_claimed(grant)),
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
