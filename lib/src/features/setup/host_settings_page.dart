import 'package:flutter/material.dart';
import '../naming/ask_for_a_name.dart';
import '../host_setup/host_product_controller.dart';
import 'commissioning_transport.dart';
import 'controller_key_bridge.dart';
import 'controller_recovery_page.dart';
import 'host_registry.dart';
import 'host_identity_summary.dart';
import 'setup_wizard_page.dart';

class HostSettingsPage extends StatefulWidget {
  const HostSettingsPage({
    super.key,
    required this.host,
    required this.onHostUpdated,
    required this.onHostRenamed,
    required this.onHostRemoved,
    this.setupTransport,
    this.controllerKeys,
    required this.controller,
    required this.onOpenControllers,
    required this.onRenameOwner,
    required this.onChangeNetwork,
  });

  final ManagedHost host;
  final ManagedHostUpdater onHostUpdated;
  final Future<void> Function(String name) onHostRenamed;
  final Future<void> Function(String hostId) onHostRemoved;
  final CommissioningTransport? setupTransport;
  final ControllerKeyBridge? controllerKeys;
  final HostProductController controller;
  final VoidCallback onOpenControllers;
  final VoidCallback onRenameOwner;
  final VoidCallback onChangeNetwork;

  @override
  State<HostSettingsPage> createState() => _HostSettingsPageState();
}

class _HostSettingsPageState extends State<HostSettingsPage> {
  ManagedHost get host => widget.controller.host;

  CommissioningTransport? get setupTransport => widget.setupTransport;
  ControllerKeyBridge? get controllerKeys => widget.controllerKeys;
  ManagedHostUpdater get onHostUpdated => widget.onHostUpdated;
  Future<void> Function(String hostId) get onHostRemoved =>
      widget.onHostRemoved;

  /// What this Host is called is this phone's to decide.
  ///
  /// A Host names itself after its own identifier, so a second one looks like
  /// the first with different hex. The name lives in this phone's registry
  /// rather than on the Host, and that is the whole story: nothing is asked of
  /// the Host, and nothing about it changes.
  Future<void> _renameHost() async {
    final name = await askForAName(
      context,
      question: '这台主机叫什么？',
      hint: '比如「书房那台」',
      current: host.displayName,
      dialogKey: const Key('rename-host-dialog'),
      fieldKey: const Key('host-name-field'),
      confirmKey: const Key('confirm-host-name'),
    );
    if (name == null || name == host.displayName) return;
    await widget.onHostRenamed(name);
  }

  Future<void> _manageControllers() async {
    if (widget.controller.connection == null) await widget.controller.connect();
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (widget.controller.connection == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.controller.connectionError ?? '暂时无法连接主机')));
      return;
    }
    widget.onOpenControllers();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => Scaffold(
            key: const Key('host-settings-page'),
            appBar: AppBar(
              title: const Text('主机设置'),
              actions: [
                IconButton(
                  key: const Key('rename-host'),
                  onPressed: _renameHost,
                  tooltip: '改名',
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        const CircleAvatar(
                            radius: 24, child: Icon(Icons.memory)),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                host.displayName,
                                style:
                                    Theme.of(context).textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 4),
                              HostIdentitySummary(
                                  host: host, status: '已保存的主机资料'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                ListTile(
                  key: const Key('change-host-network'),
                  leading: const Icon(Icons.wifi),
                  title: const Text('更换 Wi-Fi'),
                  subtitle: const Text('保留主机身份和数据；需要靠近主机'),
                  onTap: widget.onChangeNetwork,
                ),
                ListTile(
                  key: const Key('settings-owner-name'),
                  leading: const Icon(Icons.person_outline),
                  title: const Text('我的称呼'),
                  subtitle: Text(widget.controller.workspace?.owner == null
                      ? '连接并读取主人资料后可用'
                      : '伙伴如何称呼你'),
                  onTap: widget.controller.workspace?.owner == null
                      ? null
                      : widget.onRenameOwner,
                ),
                ListTile(
                  key: const Key('open-managed-controllers'),
                  leading: const Icon(Icons.admin_panel_settings_outlined),
                  title: const Text('管理手机'),
                  subtitle: Text(widget.controller.connection == null
                      ? '连接并查看'
                      : '查看、添加或撤销管理这台主机的手机'),
                  onTap: _manageControllers,
                ),
                const SizedBox(height: 20),
                Text(
                  '恢复',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  key: const Key('controller-recovery'),
                  leading: const Icon(Icons.phonelink_erase_outlined),
                  title: const Text('手机丢失或重新认领'),
                  // Open, but honest about what it needs: the Host opens the
                  // window, not this phone. An entry that could open it remotely
                  // would hand the same key to whoever stole the phone.
                  subtitle: const Text('需要有人在主机旁边开一次限时窗口；会撤销所有已授权手机'),
                  onTap: () => _openControllerRecovery(context),
                ),
                ListTile(
                  key: const Key('forget-managed-host'),
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('不再管理这台主机'),
                  subtitle: const Text('这台手机会忘记它；主机本身不受影响'),
                  onTap: () => _confirmForget(context),
                ),
                const SizedBox(height: 20),
                // Kept, but no longer the first thing about a Host. These are what
                // one machine is called by other machines; an Owner needs them
                // when something has gone wrong, and never before that.
                Card(
                  child: ExpansionTile(
                    key: const Key('host-technical-identity'),
                    leading: const Icon(Icons.fingerprint),
                    title: const Text('技术信息'),
                    subtitle: const Text('出问题时用得上'),
                    childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('主机 ID',
                          style: Theme.of(context).textTheme.labelMedium),
                      SelectableText(host.hostId),
                      const SizedBox(height: 8),
                      Text('Controller',
                          style: Theme.of(context).textTheme.labelMedium),
                      SelectableText(host.controllerId),
                      if (widget.controller.connection
                          case final connection?) ...[
                        const SizedBox(height: 8),
                        Text(
                            '本次管理会话有效至 ${connection.sessionExpiresAt.toLocal()}'),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ));

  /// Explain the recovery, then hand the Owner back to the claim flow.
  ///
  /// Re-claiming produces a new Controller grant for the same Host, so the
  /// registry entry is updated rather than added — and the name this phone
  /// gave the Host is this phone's, so it survives the Host forgetting who
  /// held it.
  Future<void> _openControllerRecovery(BuildContext context) async {
    final recovered = await Navigator.of(context).push<ManagedHost>(
      MaterialPageRoute(
        builder: (recoveryContext) => ControllerRecoveryPage(
          host: host,
          onReclaim: () async {
            final reclaimed =
                await Navigator.of(recoveryContext).push<ManagedHost>(
              MaterialPageRoute(
                builder: (wizardContext) => SetupWizardPage(
                  transport: setupTransport,
                  controllerKeys: controllerKeys,
                  onComplete: (reclaimed) async {
                    final renamed =
                        reclaimed.copyWith(displayName: host.displayName);
                    await onHostUpdated(renamed);
                    if (wizardContext.mounted) {
                      Navigator.of(wizardContext).pop(renamed);
                    }
                  },
                ),
              ),
            );
            if (recoveryContext.mounted && reclaimed != null) {
              Navigator.of(recoveryContext).pop(reclaimed);
            }
          },
        ),
      ),
    );
    if (context.mounted && recovered != null) {
      Navigator.of(context).pop(recovered);
    }
  }

  Future<void> _confirmForget(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('confirm-forget-host'),
        title: Text('移除 ${host.displayName}？'),
        content: const Text(
          '这只会让这台手机忘记它。主机上的 Owner、设备和数据都不受影响；'
          '如果它还在，可以重新设置一次把它加回来。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-forget-host-action'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await onHostRemoved(host.hostId);
    if (context.mounted) Navigator.of(context).pop();
  }
}
