import 'package:flutter/material.dart';

import 'host_registry.dart';
import 'setup_models.dart';

/// Recover one peer grant without disturbing other administrators.
class ControllerRecoveryPage extends StatelessWidget {
  const ControllerRecoveryPage({
    super.key,
    required this.host,
    required this.onReclaim,
  });

  final ManagedHost host;
  final VoidCallback onReclaim;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: const Key('controller-recovery-page'),
      appBar: AppBar(title: const Text('恢复管理权限')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text('让这台主机重新接受一台手机', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 12),
                Text(
                  '${host.readableName} 只认它已经授权过的管理手机。'
                  '如果那台手机丢了、坏了，或者这台手机重装过 App 导致管理凭据被清空，'
                  '需要为这台手机添加新的管理授权，其他手机可以继续使用。',
                ),
                const SizedBox(height: 24),
                _Requirement(
                  icon: Icons.devices,
                  title: '由任意管理手机邀请',
                  detail: '另一台已授权手机可以在管理手机列表中生成 Setup 码。所有管理手机权限平等。',
                ),
                _Requirement(
                  icon: Icons.person_pin_circle_outlined,
                  title: '也可以在主机上取得 Setup 码',
                  detail: '没有可用的管理手机时，在主机上执行下方命令。无需撤销其他手机的授权。',
                ),
                _Requirement(
                  icon: Icons.shield_outlined,
                  title: '已有授权、数据和网络保留',
                  detail: '这次只为当前手机添加授权。主机、伙伴、记忆和设备归属不变。',
                ),
                const SizedBox(height: 8),
                Card(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('在主机上执行', style: theme.textTheme.labelLarge),
                        const SizedBox(height: 8),
                        const SelectableText(
                          key: Key('recovery-command'),
                          'eidolon-ops commissioning-code',
                          style: TextStyle(fontFamily: 'monospace'),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '使用命令返回的 Setup 码重新添加主机。有效期以主机返回的信息为准。',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const Key('recovery-reclaim'),
                  onPressed: onReclaim,
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('窗口已打开，现在重新认领'),
                ),
                const SizedBox(height: 12),
                Text(controllerRecoveryGuidance,
                    style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Requirement extends StatelessWidget {
  const _Requirement({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(detail),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
