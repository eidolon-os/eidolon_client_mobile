import 'package:flutter/material.dart';

import 'host_registry.dart';
import 'setup_models.dart';

/// What an Owner does when no phone holds this Host any more.
///
/// This page deliberately cannot perform the recovery. Reinstalling the App
/// throws away the Controller credential, and the Host then correctly refuses
/// a phone it has never authorized — so a phone that could grant itself
/// authority again would hand the same key to whoever stole it. The window is
/// opened at the Host, by someone who can reach it, and this page exists to
/// say that out loud.
///
/// Before it, the entry read "尚未开放" and an Owner standing in front of a
/// working Host with a working phone had nothing to read and nothing to do.
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
      appBar: AppBar(title: const Text('手机丢失或重新认领')),
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
                  '主机会正确地拒绝它 —— 这时需要在主机那一侧重新开一次认领窗口。',
                ),
                const SizedBox(height: 24),
                _Requirement(
                  icon: Icons.person_pin_circle_outlined,
                  title: '需要有人在主机旁边',
                  detail: '开窗这一步只能在主机自己身上完成：需要能登进这台主机的人执行一条命令。'
                      '这台 App 不能远程开这条通道 —— 能远程开的钥匙，偷走手机的人也拿得到。',
                ),
                _Requirement(
                  icon: Icons.phonelink_erase_outlined,
                  title: '代价：撤销所有已授权的管理手机',
                  detail: '包括现在还能用的那些。窗口打开后，家里其他手机都需要重新认领一次。',
                  destructive: true,
                ),
                _Requirement(
                  icon: Icons.shield_outlined,
                  title: '主机上的数据不会丢',
                  detail: 'Owner、Companion、人格与记忆、已添加的设备和它们的挂载、'
                      '保存的 Wi-Fi 都保留。换掉的只是「谁能管这台主机」。',
                ),
                _Requirement(
                  icon: Icons.timer_outlined,
                  title: '窗口是限时的',
                  detail: '命令会当场给出一个 8 位 Setup 码和它的关闭时间。'
                      '过期之后需要重新执行一次；一直敞开的主机等于属于下一个路过的人。',
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
                          'eidolon-ops --config HOST.toml controller-reset --apply',
                          style: TextStyle(fontFamily: 'monospace'),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '它会在同一步里撤销全部管理手机并打开认领窗口，'
                          '输出里的 setup_session 就是这台手机接下来要用的 Setup 码。',
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
                Text(controllerResetGuidance, style: theme.textTheme.bodySmall),
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
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: destructive ? scheme.error : null),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: destructive ? scheme.error : null,
                        ),
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
