import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../device_management/mounted_device_models.dart';
import 'workspace_runtime_models.dart';

/// One place that is the Eidolon.
///
/// Everything about it used to be rows on the Host's connection card, beside
/// service state and session expiry — which is the Host's story, not its. A
/// Host is a machine someone owns; the Eidolon is who they talk to. Putting
/// the second inside the first made the person read past infrastructure to
/// find the thing they came for.
class CompanionPage extends StatelessWidget {
  const CompanionPage({
    super.key,
    required this.runtime,
    required this.devices,
    required this.onRename,
    required this.onOpenHistory,
    this.onOpenRecollections,
    this.face,
    this.onChangeFace,
    this.onClearFace,
  });

  final WorkspaceRuntime runtime;

  /// Everything this Host has mounted. Which of them belong to this Eidolon is
  /// decided here rather than asked for separately: the Host already answered.
  final MountedDeviceInventory? devices;
  final VoidCallback onRename;
  final VoidCallback onOpenHistory;

  /// Null on a Host too old to be asked what it remembers.
  final VoidCallback? onOpenRecollections;

  /// What it looks like, when it looks like anything yet.
  final Uint8List? face;
  final VoidCallback? onChangeFace;
  final VoidCallback? onClearFace;

  List<MountedDevice> get _itsDevices =>
      (devices?.devices ?? const <MountedDevice>[])
          .where(
            (device) =>
                device.mount.attachedCompanionId ==
                runtime.primaryCompanion.companionId,
          )
          .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final companion = runtime.primaryCompanion;
    final name = companion.displayName.isNotEmpty
        ? companion.displayName
        : '这个 Eidolon';
    final bound = _itsDevices;
    return Scaffold(
      key: const Key('companion-page'),
      appBar: AppBar(title: Text(name)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  GestureDetector(
                    key: const Key('companion-face'),
                    onTap: onChangeFace,
                    child: CircleAvatar(
                      radius: 26,
                      foregroundImage:
                          face == null ? null : MemoryImage(face!),
                      child: face == null
                          ? const Icon(Icons.face_retouching_natural)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '你好，${runtime.owner.displayName}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('companion-rename'),
                    onPressed: onRename,
                    tooltip: '改名',
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (onChangeFace != null)
            Card(
              child: Column(
                children: [
                  ListTile(
                    key: const Key('companion-change-face'),
                    leading: const Icon(Icons.image_outlined),
                    title: Text(face == null ? '给它一张脸' : '换一张脸'),
                    subtitle: const Text('从相册里选一张照片,它会用这张脸出现'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: onChangeFace,
                  ),
                  if (face != null && onClearFace != null)
                    ListTile(
                      key: const Key('companion-clear-face'),
                      leading: const Icon(Icons.hide_image_outlined),
                      title: const Text('不要这张脸'),
                      subtitle: const Text('它会回到没有脸的样子'),
                      onTap: onClearFace,
                    ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          if (onOpenRecollections != null)
            Card(
              child: ListTile(
                key: const Key('companion-open-recollections'),
                leading: const Icon(Icons.menu_book_outlined),
                title: const Text('它记得什么'),
                subtitle: const Text('问问看,它记住的东西留在这台主机上'),
                trailing: const Icon(Icons.chevron_right),
                onTap: onOpenRecollections,
              ),
            ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              key: const Key('companion-open-history'),
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('它的变化'),
              subtitle: const Text('看看它变成过什么样，也可以让它回到之前'),
              trailing: const Icon(Icons.chevron_right),
              onTap: onOpenHistory,
            ),
          ),
          const SizedBox(height: 16),
          Text('它的设备', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (bound.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(18),
                child: Text(
                  '还没有设备连到它。设备添加好之后会出现在这里。',
                  key: Key('companion-devices-empty'),
                ),
              ),
            )
          else
            ...bound.map(
              (device) => Card(
                child: ListTile(
                  key: Key('companion-device-${device.deviceId}'),
                  leading: const Icon(Icons.developer_board_outlined),
                  title: Text(device.label),
                  // What it is to this Eidolon, not what state a mount is in:
                  // a device attached to it is somewhere it can be spoken to.
                  subtitle: const Text('可以通过它和你说话'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
