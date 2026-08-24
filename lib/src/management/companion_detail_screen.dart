import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'management_client.dart';
import '../protocol/companion_contract.dart';

/// One Eidolon, opened from the roster.
///
/// Read-only, and it says so by having nothing to press. Renaming, archiving
/// and making one the default are writes; a screen that showed those controls
/// greyed out would be promising something this Host cannot do yet, and a
/// screen that showed them working would be lying.
///
/// It carries `revision` without displaying it. The number means nothing to a
/// person, but the first write from this screen will have to present it, and
/// having it already read is the difference between one round trip and two —
/// the second of which could see a different value.
class CompanionDetailScreen extends StatefulWidget {
  const CompanionDetailScreen({
    super.key,
    required this.companionId,
    required this.load,
  });

  final String companionId;
  final Future<CompanionDetailView> Function(String companionId) load;

  @override
  State<CompanionDetailScreen> createState() => _CompanionDetailScreenState();
}

class _CompanionDetailScreenState extends State<CompanionDetailScreen> {
  CompanionDetailView? _companion;
  Object? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final companion = await widget.load(widget.companionId);
      if (!mounted) return;
      setState(() {
        _companion = companion;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final companion = _companion;
    final name = (companion?.displayName ?? '').isNotEmpty
        ? companion!.displayName!
        : '还没有名字的 Eidolon';
    return Scaffold(
      key: const Key('companion-detail-screen'),
      appBar: AppBar(title: Text(_busy && companion == null ? '打开中' : name)),
      body: _body(companion),
    );
  }

  Widget _body(CompanionDetailView? companion) {
    if (companion == null) {
      return Center(
        child: _busy
            ? const CircularProgressIndicator(key: Key('detail-loading'))
            : Padding(
                key: const Key('detail-error'),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      // 404 here is "not one of yours", which is also the
                      // answer when the id never existed. Saying more would
                      // turn this screen into a way to test identifiers.
                      _error is ManagementRequestException &&
                              (_error as ManagementRequestException)
                                      .statusCode ==
                                  404
                          ? '这台主机上没有这个 Eidolon'
                          : '$_error',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      key: const Key('detail-retry'),
                      onPressed: _read,
                      child: const Text('再试一次'),
                    ),
                  ],
                ),
              ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const CircleAvatar(
                      radius: 26,
                      child: Icon(Icons.face_retouching_natural),
                    ),
                    const SizedBox(width: 14),
                    if (companion.isDefault)
                      const Chip(
                        key: Key('detail-default-badge'),
                        label: Text('默认'),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(companionLifecycleSentence(companion.lifecycleState)),
                const SizedBox(height: 6),
                Text(
                  _kindSentence(companion.kind),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A kind is the Host's to grow, so an unfamiliar one is described as such
/// rather than shown raw or assumed ordinary.
String _kindSentence(String kind) => switch (kind) {
      'standard' => '你日常对话的 Eidolon',
      'guard' => '守卫用途的 Eidolon',
      _ => '这台 Host 上的另一类 Eidolon',
    };
