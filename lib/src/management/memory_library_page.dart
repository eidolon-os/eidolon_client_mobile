import 'package:flutter/material.dart';

import '../generated/management_v1.dart';

/// 记忆库：what an Eidolon remembers, arranged the way it files it.
///
/// Until now the only shape a person's memory had in this app was a search box.
/// Search answers "do you remember X"; this answers "what do you have", which is
/// the question someone asks before they know what to search for.
///
/// Three things this page is careful about, all of them about not lying:
///
/// - **Withheld entries are shown as a number, not hidden.** The total and the
///   listed entries differ on purpose — "don't bring this up" is honoured, not
///   erased — and a screen that silently dropped the difference would look like
///   a bug in the person's own memory.
/// - **A truncated read says so.** The Host reads a bounded window; presenting
///   that as the whole of someone's memory would be the most quietly wrong thing
///   this page could do.
/// - **A category the Host cannot name gets this app's word for it**, never the
///   identifier. Nobody ever called a memory `Wing_FromALaterRelease`.
class MemoryLibraryPage extends StatelessWidget {
  const MemoryLibraryPage({
    super.key,
    required this.library,
    this.onOpenRoom,
    this.onForget,
  });

  final MemoryLibraryView library;

  /// Opening a shelf is a later slice; null leaves rows unopenable rather than
  /// opening something that cannot fill itself.
  final void Function(MemoryWingView wing, MemoryRoomView room)? onOpenRoom;

  /// Offered only where the Host says it can govern this memory at all. Null
  /// hides the action rather than disabling it: a visible dead control is a
  /// promise the Host has not made.
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    final wings = library.wings;
    return Scaffold(
      key: const Key('memory-library-page'),
      appBar: AppBar(
        title: const Text('它记住的'),
        actions: [
          if (onForget != null)
            IconButton(
              key: const Key('memory-library-forget'),
              onPressed: onForget,
              tooltip: '让它忘掉',
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: wings.isEmpty
          ? const Center(
              key: Key('memory-library-empty'),
              // Said plainly. An Eidolon that has not been talked to yet
              // remembers nothing, and that is not a fault.
              child: Text('还没有记下什么'),
            )
          : ListView(
              key: const Key('memory-library-list'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _Preamble(library: library),
                for (final wing in wings)
                  _WingSection(wing: wing, onOpenRoom: onOpenRoom),
              ],
            ),
    );
  }
}

class _Preamble extends StatelessWidget {
  const _Preamble({required this.library});

  final MemoryLibraryView library;

  @override
  Widget build(BuildContext context) {
    // The contract makes these required, so they are read rather than
    // defended against — a `?? 0` here would be guarding against a shape the
    // generated type says cannot arrive.
    final withheld = library.withheldCount;
    final lines = <String>[
      '共 ${library.entryCount} 条',
      if (withheld > 0) '另有 $withheld 条你说过别提，它记着但不会翻出来',
      if (library.truncated) '这次只读了一部分，下面不是全部',
    ];
    return Padding(
      key: const Key('memory-library-preamble'),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(line, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _WingSection extends StatelessWidget {
  const _WingSection({required this.wing, required this.onOpenRoom});

  final MemoryWingView wing;
  final void Function(MemoryWingView wing, MemoryRoomView room)? onOpenRoom;

  @override
  Widget build(BuildContext context) {
    final name = (wing.displayName ?? '').isNotEmpty ? wing.displayName! : '其他';
    return Card(
      key: Key('memory-wing-${wing.wingId}'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(name, style: Theme.of(context).textTheme.titleMedium),
                ),
                Text('${wing.entryCount}'),
              ],
            ),
            if ((wing.description ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  wing.description!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            for (final room in wing.rooms) _RoomRow(wing: wing, room: room, onOpen: onOpenRoom),
          ],
        ),
      ),
    );
  }
}

class _RoomRow extends StatelessWidget {
  const _RoomRow({required this.wing, required this.room, required this.onOpen});

  final MemoryWingView wing;
  final MemoryRoomView room;
  final void Function(MemoryWingView wing, MemoryRoomView room)? onOpen;

  @override
  Widget build(BuildContext context) {
    final titles = room.titles;
    return ListTile(
      key: Key('memory-room-${wing.wingId}-${room.roomId}'),
      contentPadding: EdgeInsets.zero,
      title: Row(
        children: [
          Expanded(child: Text(room.roomId)),
          Text(
            '${room.entryCount}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      subtitle: titles.isEmpty
          ? null
          : Text(
              // The Host sent a few titles, not the contents. Saying "还有" is
              // how the person knows the shelf is deeper than what they see.
              room.more ? '${titles.join('、')} 等' : titles.join('、'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: onOpen == null ? null : const Icon(Icons.chevron_right),
      onTap: onOpen == null ? null : () => onOpen!(wing, room),
    );
  }
}
