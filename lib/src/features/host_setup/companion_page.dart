import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import '../device_management/mounted_device_models.dart';
import 'home_models.dart';

/// One place that is **one** Eidolon.
///
/// Everything about it used to be rows on the Host's connection card, beside
/// service state and session expiry — which is the Host's story, not its. A
/// Host is a machine someone owns; the Eidolon is who they talk to. Putting the
/// second inside the first made the person read past infrastructure to find the
/// thing they came for.
///
/// It takes the Companion it is about. It used to take the whole home read and
/// pull `answering` out of it, which meant this page could only ever be the
/// Eidolon that replies when nobody was named — so somebody with three of them
/// could open exactly one, and the other two had no page at all. Which one
/// answers unaddressed is a setting on the Owner; it was never a statement
/// about which Eidolons are worth looking at.
class CompanionPage extends StatelessWidget {
  const CompanionPage({
    super.key,
    required this.companion,
    this.isDefault = false,
    this.onChangeLifecycle,
    required this.devices,
    required this.onRename,
    required this.onOpenPersona,
    this.onOpenRecollections,
    this.onOpenTasks,
    this.onOpenConversations,
    this.face,
    this.onChangeFace,
    this.onClearFace,
    this.hostContext,
  });

  /// What is mine, right now. The Eidolon that answers is the subject of this
  /// page; the counts and the machine line belong to the screen that opened it.
  /// The Eidolon this page is about.
  final HostCompanion companion;

  /// Whether the Owner's pointer names this one — 「没指名时由它回答」.
  ///
  /// Passed in rather than derived here: it is one comparison against the
  /// Owner's single pointer, and a page that worked it out for itself would be
  /// a second place that can disagree about which Eidolon is the default.
  final bool isDefault;

  /// Put it away, or bring it back. Null when this Host cannot, and the button
  /// is then absent rather than present and refused.
  final VoidCallback? onChangeLifecycle;

  /// Everything this Host has mounted. Which of them belong to this Eidolon is
  /// decided here rather than asked for separately: the Host already answered.
  final MountedDeviceInventory? devices;
  final VoidCallback onRename;
  /// Open who it is, to change it.
  ///
  /// Where 「它的变化」 used to be. The record of what this Eidolon has been is
  /// still kept and still appended to by every edit; it is simply not on screen
  /// while nothing but a person writes to it. It comes back when genomes start
  /// evolving on their own, which is the case it was built for — a history
  /// somebody can only fill in themselves is an undo log wearing a bigger name.
  final VoidCallback onOpenPersona;

  /// Null on a Host too old to be asked what it remembers.
  final VoidCallback? onOpenRecollections;

  /// Null while nothing is behind it. The long tasks this Eidolon was given —
  /// the one place a person can stop something it is doing.
  final VoidCallback? onOpenTasks;

  /// When we talked, and what was said each time. Null while nothing is behind
  /// it.
  final VoidCallback? onOpenConversations;

  /// What it looks like, when it looks like anything yet.
  final Uint8List? face;
  final VoidCallback? onChangeFace;
  final VoidCallback? onClearFace;

  /// What this Host says it can do at all, so a row it cannot serve is shown as
  /// held back rather than shown as working or removed without explanation.
  ///
  /// Null while it has not been read. Absent is treated as "no objection": a
  /// Host that has not answered yet must not make every feature look withdrawn.
  final ManagementContextView? hostContext;

  /// Why this row is not openable, or null if there is nothing to say.
  ///
  /// Named per row here rather than passed in as a map, because which row is
  /// which feature is this page's knowledge — and the alternative is a caller
  /// that has to keep a parallel list of capability names in step with a list
  /// of widgets.
  String? _hold(String capability) {
    final context = hostContext;
    if (context == null) return null;
    return capabilityHold(context, capability);
  }

  List<MountedDevice> get _itsDevices =>
      (devices?.devices ?? const <MountedDevice>[])
          .where(
            (device) =>
                device.attachedCompanionId == companion.companionId,
          )
          .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final name =
        companion.displayName.isNotEmpty ? companion.displayName : '这个 Eidolon';
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
                      foregroundImage: face == null ? null : MemoryImage(face!),
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
                        // What state *this Eidolon* is in. It used to greet the
                        // Owner here — 「你好，Manson」 under the Eidolon's name,
                        // with a pencil beside it — which made the card read as
                        // the person's own profile and the pencil look like it
                        // renamed them. It renames the Eidolon.
                        Text(
                          _stateLine(companion),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        if (isDefault) ...[
                          const SizedBox(height: 6),
                          const Chip(
                            key: Key('companion-default-badge'),
                            label: Text('没指名时由它回答'),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
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
          _FeatureRow(
            tileKey: const Key('companion-open-recollections'),
            icon: Icons.menu_book_outlined,
            title: '它记得什么',
            subtitle: '问问看,它记住的东西留在这台主机上',
            onOpen: onOpenRecollections,
            hold: _hold('memory.read'),
          ),
          _FeatureRow(
            tileKey: const Key('companion-open-tasks'),
            icon: Icons.checklist_outlined,
            title: '交给它的事',
            subtitle: '看它做到哪了，也可以让它别做了',
            onOpen: onOpenTasks,
            hold: _hold('task.read'),
          ),
          _FeatureRow(
            tileKey: const Key('companion-open-conversations'),
            icon: Icons.forum_outlined,
            title: '说过的话',
            subtitle: '哪天聊过，以及那次说了什么',
            onOpen: onOpenConversations,
            hold: _hold('conversation.read'),
          ),
          _FeatureRow(
            tileKey: const Key('companion-open-persona'),
            icon: Icons.auto_awesome_outlined,
            title: '它是谁',
            subtitle: '它怎么看自己、在乎什么、不会做什么、怎么说话',
            onOpen: onOpenPersona,
            hold: _hold('persona.author'),
          ),
          if (onChangeLifecycle != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: const Key('companion-lifecycle'),
                onPressed: onChangeLifecycle,
                child: Text(companion.isPutAway ? '让它回来' : '收起来'),
              ),
            ),
          ],
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

/// One thing a person can open about their Eidolon, or the reason they cannot.
///
/// Three states, and the third is the one this page could not express before:
///
/// - **openable** — a callback and no objection from the Host;
/// - **held back** — the Host says it cannot serve this, so the row stays and
///   says which kind of cannot. A row that silently vanished taught people the
///   feature was gone; a row that opened onto a page that always fails is the
///   thing the capability contract exists to prevent. Saying so is the third
///   option, and it is the honest one on a product where the person holding the
///   phone is usually the person who owns the Host.
/// - **absent** — nothing wired behind it in this build at all, which is not a
///   fact about the Host and so is not narrated.
class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.tileKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onOpen,
    required this.hold,
  });

  final Key tileKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onOpen;
  final String? hold;

  @override
  Widget build(BuildContext context) {
    if (onOpen == null && hold == null) return const SizedBox.shrink();
    final withheld = hold != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: ListTile(
          key: tileKey,
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: withheld
              ? Chip(label: Text(hold!))
              : const Icon(Icons.chevron_right),
          enabled: !withheld,
          onTap: withheld ? null : onOpen,
        ),
      ),
    );
  }
}


/// What state this Eidolon is in, for the line under its name.
///
/// Life first: one that has been put away is put away whatever the runtime
/// says, because that is the person's own decision and it outranks a machine
/// state. Unknown is said rather than rendered as "not running" — the screens
/// this replaces printed 运行中 whenever the Owner had a default Eidolon, which
/// read a routing setting as a runtime fact.
String _stateLine(HostCompanion companion) {
  if (companion.isPutAway) return '已经收起来了';
  return switch (companion.running) {
    true => '这台主机正在运行它',
    false => '这台主机现在没有在运行它',
    _ => '运行状态读不到',
  };
}
