import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../generated/management_v1.dart';
import '../device_management/mounted_device_models.dart';
import 'shared_conversation_preparation_page.dart';

typedef DeviceConversationCommand = Future<DeviceConversationStatus> Function(
    String action, String sessionId, ConversationStart? selection);

class DeviceConversationPage extends StatefulWidget {
  const DeviceConversationPage(
      {super.key, required this.load, required this.command});
  final Future<SharedConversationSnapshot> Function() load;
  final DeviceConversationCommand command;
  @override
  State<DeviceConversationPage> createState() => _DeviceConversationPageState();
}

class _DeviceConversationPageState extends State<DeviceConversationPage> {
  List<MountedDevice>? _devices;
  String? _input, _output, _companion, _session;
  String _state = 'closed';
  String? _notice;
  bool _busy = false;
  bool _loading = false;
  String? _inventoryError;
  String _coverage = '';
  int _inventoryRevision = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  // The current single-Companion endpoint requires an attached Companion.
  // Keep unavailable devices visible instead of silently shrinking inventory.
  String? _unavailable(MountedDevice device) {
    if (device.state == MountedDeviceState.accessRevoked) return '设备访问已撤销';
    if (device.state == MountedDeviceState.awaitingOutputs) return '请先配置设备输出';
    if (device.attachedCompanionId?.isNotEmpty != true) return '尚未绑定伙伴';
    return null;
  }

  Future<void> _load() async {
    if (_loading || _session != null || _busy) return;
    setState(() {
      _loading = true;
      _inventoryError = null;
    });
    try {
      final snapshot = await widget.load();
      if (!mounted) return;
      final devices = snapshot.devices
          .where((d) => d.deviceId != snapshot.localDeviceId)
          .toList();
      final eligible = devices.where((d) => _unavailable(d) == null);
      final ids = eligible.map((d) => d.deviceId).toSet();
      final companions = eligible.map((d) => d.attachedCompanionId).toSet();
      setState(() {
        _devices = devices;
        _coverage = snapshot.coverage;
        if (!ids.contains(_input)) _input = null;
        if (!ids.contains(_output)) _output = null;
        if (!companions.contains(_companion)) _companion = null;
        _inventoryRevision++;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _inventoryError = '暂时无法读取设备，请刷新重试。');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _accept(DeviceConversationStatus result) {
    if (!mounted || result.sessionId != _session) return;
    setState(() {
      _state = result.state;
      _notice = switch (result.state) {
        'preparing' => '正在准备两台设备…',
        'ready' => '已准备好。请从输入设备说话，回复由播放设备播出。',
        'closing' => '正在结束对话…',
        'closed' => '对话已结束，可以使用原来的单聊。',
        'failed' => '未能建立对话，请结束后重试。',
        _ => '正在确认设备状态…',
      };
      if (result.state == 'closed') _session = null;
    });
    if (_session != null && result.state != 'failed') {
      _poll?.cancel();
      _poll = Timer(const Duration(seconds: 2), _status);
    }
  }

  Future<void> _status() async {
    final id = _session;
    if (id == null || _busy) return;
    try {
      _accept(await widget.command('status', id, null));
    } catch (_) {
      if (mounted && _session == id) {
        setState(() => _notice = '暂时无法确认状态，可尝试结束对话。');
        _poll = Timer(const Duration(seconds: 2), _status);
      }
    }
  }

  Future<void> _change(bool open) async {
    if (_busy || (open && (_loading || _inventoryError != null))) return;
    _poll?.cancel();
    _session ??=
        'mobile-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
    setState(() => _busy = true);
    try {
      _accept(await widget.command(
          open ? 'open' : 'close',
          _session!,
          open
              ? ConversationStart(
                  sessionId: _session!,
                  inputDeviceId: _input!,
                  outputDeviceId: _output!,
                  targetCompanionId: _companion!)
              : null));
    } catch (_) {
      if (mounted) setState(() => _notice = '未能确认结果，请尝试结束对话。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final companions = <String, String>{
      for (final d in _devices ?? <MountedDevice>[])
        if (_unavailable(d) == null)
          d.attachedCompanionId!: d.attachedCompanionName.isNotEmpty
              ? d.attachedCompanionName
              : d.attachedCompanionId!,
    };
    final editable =
        _session == null && !_busy && !_loading && _inventoryError == null;
    Widget endpoint(
            String label, String? value, ValueChanged<String?> change) =>
        DropdownButtonFormField<String>(
            key: ValueKey((label, _inventoryRevision)),
            initialValue: value,
            isExpanded: true,
            decoration: InputDecoration(labelText: label),
            items: [
              for (final d in _devices ?? <MountedDevice>[])
                DropdownMenuItem(
                  value: d.deviceId,
                  enabled: _unavailable(d) == null,
                  child: Text(
                      _unavailable(d) == null
                          ? d.label
                          : '${d.label}（${_unavailable(d)}）',
                      overflow: TextOverflow.ellipsis),
                )
            ],
            onChanged:
                editable ? (value) => setState(() => change(value)) : null);
    return PopScope(
        canPop: _session == null,
        child: Scaffold(
            appBar: AppBar(title: const Text('跨设备对话'), actions: [
              IconButton(
                key: const Key('refresh-conversation-devices'),
                tooltip: '刷新设备',
                onPressed:
                    _session == null && !_busy && !_loading ? _load : null,
                icon: const Icon(Icons.refresh),
              ),
            ]),
            body: ListView(padding: const EdgeInsets.all(24), children: [
              const Text('当前支持一个伙伴回答：选择输入和播放设备，再选择回答的伙伴。'),
              const SizedBox(height: 8),
              const Text('列表来自当前主机；接入新设备后请刷新。'),
              if (_coverage.isNotEmpty)
                ExpansionTile(
                  title: const Text('设备列表范围'),
                  children: [Text(_coverage)],
                ),
              if (_inventoryError != null) Text(_inventoryError!),
              const SizedBox(height: 24),
              if (_loading) const Center(child: CircularProgressIndicator()),
              if (_devices?.isEmpty == true)
                const Text('当前 Host 没有其他设备。请先完成设备接入，再刷新。'),
              if (_devices != null && _devices!.isNotEmpty) ...[
                endpoint('从哪台设备说话', _input, (v) => _input = v),
                const SizedBox(height: 20),
                endpoint('在哪台设备播放', _output, (v) => _output = v),
                const SizedBox(height: 20),
                DropdownButtonFormField<String>(
                    key: ValueKey(('companion', _inventoryRevision)),
                    initialValue: _companion,
                    decoration: const InputDecoration(labelText: '本次回答的伙伴'),
                    items: [
                      for (final e in companions.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value))
                    ],
                    onChanged: editable
                        ? (v) => setState(() => _companion = v)
                        : null),
                const SizedBox(height: 24),
                if (_input != null && _input == _output)
                  const Text('请选择两台不同的设备。'),
                if (_notice != null)
                  Text(_notice!, key: const Key('device-conversation-status')),
                const SizedBox(height: 20),
                FilledButton(
                    key: const Key('device-conversation-action'),
                    onPressed: _busy
                        ? null
                        : _session != null
                            ? () => _change(false)
                            : editable &&
                                    _input != null &&
                                    _output != null &&
                                    _input != _output &&
                                    _companion != null
                                ? () => _change(true)
                                : null,
                    child: Text(_busy
                        ? '正在处理…'
                        : _session == null
                            ? '开始对话'
                            : '结束对话')),
                const SizedBox(height: 16),
                Text(_state == 'ready'
                    ? '手机可放在一旁，设备会继续对话。'
                    : '请先结束这两台设备正在进行的单聊。'),
              ],
              if (_devices == null && _notice != null) Text(_notice!),
            ])));
  }
}
