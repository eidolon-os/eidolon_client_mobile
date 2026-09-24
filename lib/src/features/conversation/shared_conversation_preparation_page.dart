import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../../management/companion_portrait.dart';
import '../../theme/eidolon_theme.dart';
import '../../theme/neon_components.dart';
import '../device_management/mounted_device_models.dart';

/// A read-only Controller projection, not a room admission or online status.
typedef SharedConversationSnapshot = ({
  List<MountedDevice> devices,
  List<CompanionSummaryView> companions,
  String? localDeviceId,
  String coverage,
});

/// Page-local preparation only. No binding, microphone or Provider capability
/// is passed here. A future start action must use trusted session admission.
class SharedConversationPreparationPage extends StatefulWidget {
  const SharedConversationPreparationPage({
    super.key,
    required this.load,
    this.loadFace,
  });
  final Future<SharedConversationSnapshot> Function() load;
  final CompanionFaceLoader? loadFace;

  @override
  State<SharedConversationPreparationPage> createState() =>
      _SharedConversationPreparationPageState();
}

class _SharedConversationPreparationPageState
    extends State<SharedConversationPreparationPage> {
  SharedConversationSnapshot? _snapshot;
  final _selected = <String, String?>{};
  String? _inputDeviceId;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final snapshot = await widget.load();
      if (!mounted) return;
      final available = snapshot.devices
          .where((d) => d.state != MountedDeviceState.accessRevoked)
          .map((d) => d.deviceId)
          .toSet();
      final companions = snapshot.companions
          .where((c) => c.lifecycleState == 'active')
          .map((c) => c.companionId)
          .toSet();
      setState(() {
        _snapshot = snapshot;
        _selected.removeWhere((id, _) => !available.contains(id));
        if (!_selected.containsKey(_inputDeviceId)) _inputDeviceId = null;
        _selected.updateAll((_, id) => companions.contains(id) ? id : null);
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<CompanionSummaryView> get _companions => _snapshot!.companions
      .where((c) => c.lifecycleState == 'active')
      .toList(growable: false);

  Future<void> _choosePartner(MountedDevice device) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .75),
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Text('谁通过 ${device.label} 回应',
                  style: Theme.of(context).textTheme.titleLarge),
            ),
            for (final companion in _companions)
              ListTile(
                leading: CompanionPortrait(
                  companionId: companion.companionId,
                  name: companion.displayName ?? companion.companionId,
                  artworkId: companion.artworkId,
                  loadFace: widget.loadFace,
                  size: 40,
                ),
                title: Text(companion.displayName ?? companion.companionId),
                trailing: _selected[device.deviceId] == companion.companionId
                    ? const Icon(Icons.check_rounded, color: Neon.cyan)
                    : null,
                onTap: () => Navigator.pop(context, companion.companionId),
              ),
            if (_companions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('还没有可参与的伙伴。请先在主机中创建伙伴。'),
              ),
          ]),
        ),
      ),
    );
    if (mounted && choice != null && _selected.containsKey(device.deviceId)) {
      setState(() => _selected[device.deviceId] = choice);
    }
  }

  Widget _device(MountedDevice device) {
    final selected = _selected.containsKey(device.deviceId);
    final selectable = device.state != MountedDeviceState.accessRevoked;
    final companion = _companions
        .where((c) => c.companionId == _selected[device.deviceId])
        .firstOrNull;
    final isLocal = device.deviceId == _snapshot!.localDeviceId;
    final isInput = device.deviceId == _inputDeviceId;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        clipBehavior: Clip.antiAlias,
        color: selected ? Neon.surfaceHigh : Neon.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Neon.radiusL),
          side: BorderSide(color: selected ? Neon.hairStrong : Neon.hair),
        ),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          CheckboxListTile(
            key: Key('select-${device.deviceId}'),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            value: selected,
            onChanged: !selectable
                ? null
                : (value) => setState(() {
                      if (value == true) {
                        _selected[device.deviceId] = _companions.any((c) =>
                                c.companionId == device.attachedCompanionId)
                            ? device.attachedCompanionId
                            : null;
                      } else {
                        _selected.remove(device.deviceId);
                        if (isInput) _inputDeviceId = null;
                      }
                    }),
            title: Text(device.label,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  !selectable
                      ? '已解除授权，不能邀请'
                      : isLocal
                          ? '本机 · 入房能力待检查'
                          : '已登记 · 入房能力待检查',
                  style: const TextStyle(color: Neon.inkDim, height: 1.5)),
            ),
          ),
          if (selected) ...[
            const Divider(height: 1, color: Neon.hair),
            ListTile(
              key: Key('partner-${device.deviceId}'),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              leading: companion == null
                  ? const Icon(Icons.person_add_alt_1_rounded,
                      color: Neon.inkDim)
                  : CompanionPortrait(
                      companionId: companion.companionId,
                      name: companion.displayName ?? companion.companionId,
                      artworkId: companion.artworkId,
                      loadFace: widget.loadFace,
                      size: 40),
              title: Text(
                  companion?.displayName ?? companion?.companionId ?? '选择伙伴'),
              subtitle: const Text('本次回应伙伴'),
              trailing: const Icon(Icons.expand_more_rounded),
              onTap: () => _choosePartner(device),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: Key('input-${device.deviceId}'),
                  onPressed: () =>
                      setState(() => _inputDeviceId = device.deviceId),
                  icon: Icon(isInput
                      ? Icons.check_circle_outline_rounded
                      : Icons.mic_none_rounded),
                  label: Text(isInput ? '当前输入入口' : '从这台设备发起'),
                ),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('一起聊'), actions: [
          IconButton(
              tooltip: '刷新设备与伙伴',
              onPressed: _loading ? null : _refresh,
              icon: const Icon(Icons.refresh_rounded)),
        ]),
        body: SafeArea(
            child: Center(
                child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _failed
                  ? Center(
                      child: Padding(
                          padding: const EdgeInsets.all(24),
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            const GlyphBadge(Icons.cloud_off_rounded,
                                color: Neon.warn),
                            const SizedBox(height: 20),
                            const Text('暂时无法读取设备与伙伴',
                                textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            FilledButton(
                                onPressed: _refresh, child: const Text('重试')),
                          ])))
                  : ListView(padding: const EdgeInsets.all(24), children: [
                      const Align(
                          alignment: Alignment.centerLeft,
                          child: StatusPill('搭配预览', tone: NeonTone.idle)),
                      const SizedBox(height: 20),
                      Text('先安排伙伴与设备',
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 12),
                      const Text('共享对话尚未开放，当前仅可预览搭配。选择参与的设备、回应的伙伴，以及本次从哪里发起对话。',
                          style: TextStyle(color: Neon.inkDim, height: 1.65)),
                      const SizedBox(height: 24),
                      Text('已选 ${_selected.length} 台设备',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      const Text('下方为主机登记的设备，尚未检查在线状态。',
                          style: TextStyle(color: Neon.inkDim, height: 1.5)),
                      const SizedBox(height: 16),
                      if (_snapshot!.coverage.isNotEmpty) ...[
                        ExpansionTile(
                          key: const Key('device-inventory-coverage'),
                          title: const Text('设备清单说明'),
                          leading: const Icon(Icons.info_outline_rounded),
                          childrenPadding: const EdgeInsets.only(bottom: 16),
                          children: [
                            Text(_snapshot!.coverage,
                                style: const TextStyle(
                                    color: Neon.inkDim, height: 1.6))
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_snapshot!.devices.isEmpty)
                        const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Text('还没有可列出的设备，请先在主机中登记设备。')),
                      for (final device in _snapshot!.devices) _device(device),
                      const SizedBox(height: 12),
                      const Text('本次搭配',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      const Text('当前可预览搭配，暂不能邀请设备。选择仅保留在此页，返回后丢弃；不会改变设备原有的伙伴。',
                          style: TextStyle(color: Neon.inkDim, height: 1.65)),
                      const SizedBox(height: 24),
                    ]),
        ))),
      );
}
