import 'package:flutter/material.dart';

import '../../generated/management_v1.dart' as management;
import '../../management/management_client.dart';
import '../host_setup/host_product_controller.dart';

/// Owner registry editor. All writes go through the Host's management session.
class SmartHomePage extends StatefulWidget {
  const SmartHomePage({super.key, required this.controller});

  final HostProductController controller;

  @override
  State<SmartHomePage> createState() => _SmartHomePageState();
}

class _SmartHomePageState extends State<SmartHomePage> {
  management.Registry? _registry;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final registry = await widget.controller.smartHomeRegistry();
      if (mounted) setState(() => _registry = registry);
      await widget.controller.refreshDevices();
    } catch (error) {
      if (mounted) setState(() => _error = refusalText(error, subject: '家居设备'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _write(String method, String path,
      {Map<String, dynamic>? body, bool delete = false}) async {
    final current = _registry;
    if (current == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.controller.smartHomeWrite(
        method: method,
        path: path,
        body: body == null
            ? null
            : {...body, 'expected_revision': current.revision},
        expectedRevision: delete ? current.revision : null,
      );
      if (mounted) setState(() => _registry = result);
    } catch (error) {
      if (error is ManagementRequestException && error.someoneElseChangedIt) {
        await _reload();
      }
      if (mounted) setState(() => _error = refusalText(error, subject: '家居设备'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _newId(String prefix) =>
      '$prefix.${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  Future<String?> _askName(String title, {String initial = ''}) async {
    final input = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(labelText: '名称'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    input.dispose();
    return result == null || result.isEmpty ? null : result;
  }

  Future<void> _addArea() async {
    final name = await _askName('添加房间');
    if (name == null) return;
    await _write('POST', management.ManagementV1.smarthomeAreasPath,
        body: {'area': management.Area(areaId: _newId('area'), name: name).toJson()});
  }

  Future<void> _renameArea(management.Area area) async {
    final name = await _askName('房间名称', initial: area.name);
    if (name == null || name == area.name) return;
    await _write('PUT', management.ManagementV1.smarthomeAreasByAreaIdPath(area.areaId),
        body: {'area': management.Area(areaId: area.areaId, name: name, order: area.order).toJson()});
  }

  Future<void> _addDevice() async {
    final areas = _registry?.areas ?? [];
    if (areas.isEmpty) {
      setState(() => _error = '请先添加房间');
      return;
    }
    final nameInput = TextEditingController();
    var areaId = areas.first.areaId;
    var kind = 'light';
    final details = await showDialog<(String, String, String)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('添加虚拟设备'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameInput,
              maxLength: 32,
              decoration: const InputDecoration(labelText: '设备名称'),
            ),
            DropdownButtonFormField<String>(
              initialValue: kind,
              decoration: const InputDecoration(labelText: '类型'),
              items: const [
                DropdownMenuItem(value: 'light', child: Text('灯')),
                DropdownMenuItem(value: 'switch', child: Text('开关')),
                DropdownMenuItem(value: 'climate', child: Text('空调')),
                DropdownMenuItem(value: 'cover', child: Text('窗帘')),
                DropdownMenuItem(value: 'fan', child: Text('风扇')),
                DropdownMenuItem(value: 'media', child: Text('影音')),
                DropdownMenuItem(value: 'appliance', child: Text('家电')),
              ],
              onChanged: (value) => update(() => kind = value ?? kind),
            ),
            DropdownButtonFormField<String>(
              initialValue: areaId,
              decoration: const InputDecoration(labelText: '房间'),
              items: [for (final area in areas)
                DropdownMenuItem(value: area.areaId, child: Text(area.name))],
              onChanged: (value) => update(() => areaId = value ?? areaId),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final name = nameInput.text.trim();
                if (name.isNotEmpty) Navigator.pop(context, (name, kind, areaId));
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    nameInput.dispose();
    if (details == null) return;
    await _write('POST', management.ManagementV1.smarthomeDevicesPath,
        body: {'device': management.Device(
          deviceId: _newId('device'),
          name: details.$1,
          type: details.$2,
          areaId: details.$3,
          provider: 'virtual',
        ).toJson()});
  }

  Future<void> _editDevice(management.Device device) async {
    final areas = _registry?.areas ?? [];
    final nameInput = TextEditingController(text: device.name);
    String? areaId = device.areaId;
    final details = await showDialog<(String, String?)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('编辑设备'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameInput, maxLength: 32,
                decoration: const InputDecoration(labelText: '名称')),
            DropdownButtonFormField<String>(
              initialValue: areaId,
              decoration: const InputDecoration(labelText: '房间'),
              items: [for (final area in areas)
                DropdownMenuItem(value: area.areaId, child: Text(area.name))],
              onChanged: (value) => update(() => areaId = value),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final name = nameInput.text.trim();
                if (name.isNotEmpty) Navigator.pop(context, (name, areaId));
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    nameInput.dispose();
    if (details == null) return;
    await _write('PUT', management.ManagementV1.smarthomeDevicesByDeviceIdPath(device.deviceId),
        body: {'device': management.Device(
          deviceId: device.deviceId,
          name: details.$1,
          type: device.type,
          aliases: device.aliases,
          areaId: details.$2,
          provider: device.provider,
          providerRef: device.providerRef,
        ).toJson()});
  }

  Future<void> _place(String deviceRef, String? areaId) => _write(
        areaId == null ? 'DELETE' : 'PUT',
        management.ManagementV1.smarthomePlacementsByDeviceRefPath(deviceRef),
        body: areaId == null ? null : {'area_id': areaId},
        delete: areaId == null,
      );

  @override
  Widget build(BuildContext context) {
    final registry = _registry;
    final areas = registry?.areas ?? [];
    final devices = registry?.devices ?? [];
    final placements = registry?.placements ?? [];
    final mounted = widget.controller.devices?.devices ?? [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('智能家居'),
        actions: [IconButton(onPressed: _busy ? null : _reload,
            tooltip: '刷新', icon: const Icon(Icons.refresh))],
      ),
      body: registry == null && _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error != null) Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
              if (registry == null) FilledButton(
                onPressed: _reload, child: const Text('重新读取')),
              if (registry != null) ...[
                Text('房间与设备', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                if (areas.isEmpty) const Text('还没有房间。可以添加房间，或装载示例公寓。'),
                for (final area in areas) ...[
                  ListTile(
                    title: Text(area.name),
                    trailing: IconButton(
                      tooltip: '编辑房间', icon: const Icon(Icons.edit_outlined),
                      onPressed: _busy ? null : () => _renameArea(area),
                    ),
                  ),
                  for (final device in devices.where((d) => d.areaId == area.areaId))
                    ListTile(
                      contentPadding: const EdgeInsets.only(left: 28, right: 8),
                      title: Text(device.name),
                      subtitle: Text(device.type),
                      trailing: IconButton(
                        tooltip: '编辑设备', icon: const Icon(Icons.edit_outlined),
                        onPressed: _busy ? null : () => _editDevice(device),
                      ),
                    ),
                ],
                Wrap(spacing: 8, children: [
                  OutlinedButton.icon(onPressed: _busy ? null : _addArea,
                      icon: const Icon(Icons.add), label: const Text('添加房间')),
                  OutlinedButton.icon(onPressed: _busy ? null : _addDevice,
                      icon: const Icon(Icons.add), label: const Text('添加设备')),
                  if (registry.revision == 0)
                    FilledButton(onPressed: _busy ? null : () => _write(
                      'POST', management.ManagementV1.smarthomeSamplesApartmentPath,
                      body: {}), child: const Text('装载示例公寓')),
                ]),
                const SizedBox(height: 24),
                Text('中控终端所在房间', style: Theme.of(context).textTheme.titleLarge),
                if (mounted.isEmpty) const Text('连接 Korvo-1 后可在这里设置它所在的房间。'),
                for (final device in mounted) ListTile(
                  title: Text(device.label),
                  subtitle: Text(device.deviceId),
                  trailing: DropdownButton<String>(
                    value: placements.where((p) => p.deviceRef == device.deviceId)
                        .firstOrNull?.areaId ?? '',
                    items: [
                      const DropdownMenuItem(value: '', child: Text('未设置')),
                      for (final area in areas)
                        DropdownMenuItem(value: area.areaId, child: Text(area.name)),
                    ],
                    onChanged: _busy || areas.isEmpty ? null
                        : (value) => _place(device.deviceId, value == '' ? null : value),
                  ),
                ),
                const SizedBox(height: 24),
                Text('场景', style: Theme.of(context).textTheme.titleLarge),
                for (final scene in registry.scenes ?? <management.Scene>[])
                  ListTile(title: Text(scene.name),
                    subtitle: Text('${scene.actions.length} 个动作')),
              ],
            ]),
    );
  }
}
