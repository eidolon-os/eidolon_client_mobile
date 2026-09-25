import 'dart:math';
import 'package:flutter/material.dart';

import '../../management/companion_portrait.dart';
import '../../theme/eidolon_theme.dart';
import '../../theme/neon_components.dart';
import '../device_management/mounted_device_models.dart';

/// A read-only Controller projection, not a room admission or online status.
typedef SharedConversationSnapshot = ({
  List<MountedDevice> devices,
  String? localDeviceId,
  String coverage,
});

/// Selection and explicit visit controls. The Host owns admission; this page
/// neither changes Companion bindings nor receives Provider credentials.
class SharedConversationPreparationPage extends StatefulWidget {
  const SharedConversationPreparationPage({
    super.key,
    required this.load,
    this.loadFace,
    this.changeSession,
  });
  final Future<SharedConversationSnapshot> Function() load;
  final CompanionFaceLoader? loadFace;
  final Future<void> Function(String, List<String>?, String?)? changeSession;

  @override
  State<SharedConversationPreparationPage> createState() =>
      _SharedConversationPreparationPageState();
}

class _SharedConversationPreparationPageState
    extends State<SharedConversationPreparationPage> {
  SharedConversationSnapshot? _snapshot;
  final _selected = <String>{};
  String? _inputDeviceId;
  bool _loading = false;
  bool _failed = false;
  bool _busy = false;
  String? _sessionId;
  String? _notice;

  Future<void> _change(bool opening) async {
    if (_busy) return;
    // Retain the ID on uncertain results: closing must target the same visit.
    _sessionId ??=
        'mobile-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await widget.changeSession!(_sessionId!,
          opening ? _selected.toList() : null, opening ? _inputDeviceId : null);
      if (!mounted) return;
      setState(() {
        _notice =
            opening ? '共享连接已建立。此轮仅检查入房与恢复，麦克风和扬声器保持关闭。' : '共享连接已结束，设备正在恢复原连接。';
        if (!opening) _sessionId = null;
      });
    } catch (_) {
      if (mounted) setState(() => _notice = '未能确认结果，请结束共享连接后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
          .where(_canParticipate)
          .map((d) => d.deviceId)
          .toSet();
      setState(() {
        _snapshot = snapshot;
        _selected.removeWhere((id) => !available.contains(id));
        if (!_selected.contains(_inputDeviceId)) _inputDeviceId = null;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _canParticipate(MountedDevice device) =>
      device.state != MountedDeviceState.accessRevoked &&
      device.attachedCompanionId?.isNotEmpty == true;

  Widget _device(MountedDevice device) {
    final selected = _selected.contains(device.deviceId);
    final selectable = _canParticipate(device);
    final companionId = device.attachedCompanionId;
    final companionName = device.attachedCompanionName.isNotEmpty
        ? device.attachedCompanionName
        : companionId ?? '尚未绑定伙伴';
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
            secondary: companionId == null
                ? null
                : CompanionPortrait(
                    companionId: companionId,
                    name: companionName,
                    loadFace: widget.loadFace,
                    size: 40),
            onChanged: !selectable || _sessionId != null
                ? null
                : (value) => setState(() {
                      if (value == true) {
                        _selected.add(device.deviceId);
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
                  device.state == MountedDeviceState.accessRevoked
                      ? '已解除授权，不能邀请'
                      : !selectable
                          ? '尚未绑定伙伴，请到设备详情设置'
                          : isLocal
                              ? '绑定伙伴：$companionName\n本机 · 入房能力待检查'
                              : '绑定伙伴：$companionName\n入房能力待检查',
                  style: const TextStyle(color: Neon.inkDim, height: 1.5)),
            ),
          ),
          if (selected) ...[
            const Divider(height: 1, color: Neon.hair),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: Key('input-${device.deviceId}'),
                  onPressed: _sessionId != null
                      ? null
                      : () => setState(() => _inputDeviceId = device.deviceId),
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
  Widget build(BuildContext context) => PopScope(
      canPop: _sessionId == null,
      child: Scaffold(
        appBar: AppBar(title: const Text('一起聊'), actions: [
          IconButton(
              tooltip: '刷新设备与伙伴',
              onPressed: _loading || _sessionId != null ? null : _refresh,
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
                      Text('选择参与的设备',
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 12),
                      Text(
                          widget.changeSession == null
                              ? '共享对话尚未开放。选择参与的设备及本次输入入口，伙伴沿用设备详情中的现有绑定。'
                              : '选择至少两台设备及本次输入入口。伙伴沿用现有绑定；当前先检查共享连接，暂不开放语音。',
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
                      if (_notice != null) ...[
                        Text(_notice!, key: const Key('shared-session-notice')),
                        const SizedBox(height: 16),
                      ],
                      if (widget.changeSession != null)
                        FilledButton(
                          key: const Key('shared-session-action'),
                          onPressed: _busy
                              ? null
                              : _sessionId != null
                                  ? () => _change(false)
                                  : _selected.length >= 2 &&
                                          _inputDeviceId != null
                                      ? () => _change(true)
                                      : null,
                          child: Text(_busy
                              ? '正在处理…'
                              : _sessionId != null
                                  ? '结束共享连接'
                                  : '检查共享连接'),
                        ),
                      const Text('本次搭配',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text(
                          widget.changeSession == null
                              ? '当前暂不能邀请设备。选择仅保留在此页，返回后丢弃。更换伙伴请到原有设备详情设置。'
                              : '共享连接最多保留两分钟。结束后恢复原连接，更换伙伴请到设备详情设置。',
                          style: TextStyle(color: Neon.inkDim, height: 1.65)),
                      const SizedBox(height: 24),
                    ]),
        ))),
      ));
}
