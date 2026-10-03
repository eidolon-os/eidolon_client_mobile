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
  List<management.ProviderAccount> _accounts = const [];
  Map<String, management.DeviceStatusView> _status = const {};
  bool _accountsAvailable = true;
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
      await _reloadEcosystem();
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

  /// Accounts and observed state live behind Hub; a Host without that
  /// credential answers 503 and the section simply says so.
  Future<void> _reloadEcosystem() async {
    try {
      final accounts = await widget.controller.smartHomeAccounts();
      final snapshot = await widget.controller.smartHomeSnapshot();
      if (mounted) {
        setState(() {
          _accounts = accounts.accounts;
          _status = snapshot.status;
          _accountsAvailable = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _accountsAvailable = false);
    }
  }

  Future<void> _ecosystem(Future<void> Function() action, {String subject = '家居平台'}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      final registry = await widget.controller.smartHomeRegistry();
      if (mounted) setState(() => _registry = registry);
      await _reloadEcosystem();
    } catch (error) {
      if (mounted) setState(() => _error = refusalText(error, subject: subject));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectAccount() async {
    final providers = (await widget.controller.smartHomeProviders()).providers;
    if (!mounted) return;
    if (providers.isEmpty) {
      setState(() => _error = '这台主机没有装配任何家居平台');
      return;
    }
    final schema = providers.length == 1
        ? providers.first
        : await showDialog<management.AccountSchema>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('连接哪个平台'),
              children: [
                for (final provider in providers)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, provider),
                    child: Text(provider.label),
                  ),
              ],
            ),
          );
    if (schema == null || !mounted) return;
    final fields = await _askAccountFields(schema);
    if (fields == null) return;
    await _ecosystem(() async {
      var account = await widget.controller.smartHomeBind(
          management.AccountBind(kind: schema.kind, fields: fields));
      // Pending: the platform wants a choice (which home); ask, then bind again.
      final choiceField = (schema.fields ?? []).where((f) => f.kind == 'choice').firstOrNull;
      if (account.status == 'pending' && choiceField != null && (account.choices ?? []).isNotEmpty) {
        if (!mounted) return;
        final chosen = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(choiceField.label),
            children: [
              for (final choice in account.choices!)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, choice.value),
                  child: Text(choice.label),
                ),
            ],
          ),
        );
        if (chosen == null) return;
        account = await widget.controller.smartHomeBind(management.AccountBind(
          kind: schema.kind,
          accountId: account.accountId,
          fields: {...fields, choiceField.name: chosen},
        ));
      }
      if (account.status == 'connected') {
        await widget.controller.smartHomeSync(account.accountId);
      }
    }, subject: schema.label);
  }

  /// One text field per declared account field; secrets are obscured, choice
  /// fields are asked for later with the platform's own options.
  Future<Map<String, String>?> _askAccountFields(management.AccountSchema schema) async {
    final inputs = <String, TextEditingController>{
      for (final field in schema.fields ?? <management.AccountField>[])
        if (field.kind != 'choice') field.name: TextEditingController(),
    };
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('连接 ${schema.label}'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final field in schema.fields ?? <management.AccountField>[])
              if (inputs.containsKey(field.name))
                TextField(
                  controller: inputs[field.name],
                  obscureText: field.kind == 'secret',
                  keyboardType: field.kind == 'url'
                      ? TextInputType.url
                      : field.kind == 'phone'
                          ? TextInputType.phone
                          : TextInputType.text,
                  decoration: InputDecoration(
                    labelText: field.label + ((field.required ?? true) ? '' : '（可选）'),
                  ),
                ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final values = {
                for (final entry in inputs.entries)
                  if (entry.value.text.trim().isNotEmpty) entry.key: entry.value.text.trim(),
              };
              final missing = (schema.fields ?? []).where((f) =>
                  f.kind != 'choice' && (f.required ?? true) && !values.containsKey(f.name));
              if (missing.isEmpty) Navigator.pop(context, values);
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
    for (final controller in inputs.values) {
      controller.dispose();
    }
    return result;
  }

  String _statusText(management.Device device) {
    if (device.orphaned ?? false) return '平台里已不存在';
    final status = _status[device.deviceId];
    if (status == null) return device.type;
    if (!status.online) return '离线';
    final state = status.state;
    final parts = <String>[];
    if (state['on'] is bool) parts.add(state['on'] == true ? '开着' : '关着');
    if (state['level'] != null) parts.add('亮度 ${state['level']}%');
    if (state['position'] != null) parts.add('开合 ${state['position']}%');
    if (state['target_c'] != null) parts.add('目标 ${state['target_c']}°C');
    if (state['current_c'] != null) parts.add('室温 ${state['current_c']}°C');
    if (state['locked'] is bool) parts.add(state['locked'] == true ? '已上锁' : '未上锁');
    if (state['temp_c'] != null) parts.add('${state['temp_c']}°C');
    if (state['humidity'] != null) parts.add('湿度 ${state['humidity']}%');
    return parts.isEmpty ? '在线' : parts.join(' · ');
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
    // An imported device keeps what the platform said about it; the fields the
    // Owner edits by hand are recorded so the next sync leaves them alone.
    final overrides = {...?device.overrides};
    if (details.$1 != device.name) overrides.add('name');
    if (details.$2 != device.areaId) overrides.add('area_id');
    await _write('PUT', management.ManagementV1.smarthomeDevicesByDeviceIdPath(device.deviceId),
        body: {'device': management.Device(
          deviceId: device.deviceId,
          name: details.$1,
          type: device.type,
          aliases: device.aliases,
          areaId: details.$2,
          provider: device.provider,
          providerRef: device.providerRef,
          traits: device.traits,
          limits: device.limits,
          source: device.source,
          overrides: device.source == 'imported' ? (overrides.toList()..sort()) : device.overrides,
          syncedAtMs: device.syncedAtMs,
          orphaned: device.orphaned,
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
                      subtitle: Text(_statusText(device)),
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
                      icon: const Icon(Icons.add), label: const Text('添加虚拟设备')),
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
                    subtitle: Text(scene.providerRef != null
                        ? '由平台执行'
                        : '${scene.actions?.length ?? 0} 个动作')),
                const SizedBox(height: 24),
                Text('家居平台', style: Theme.of(context).textTheme.titleLarge),
                if (!_accountsAvailable)
                  const Text('这台主机还没有开通家居平台连接。')
                else ...[
                  if (_accounts.isEmpty) const Text('还没有连接任何平台。连接后可以把平台里的设备导入到这里。'),
                  for (final account in _accounts)
                    ListTile(
                      title: Text(account.label),
                      subtitle: Text([
                        account.kind,
                        switch (account.status) {
                          'connected' => '已连接',
                          'pending' => '待选择',
                          'degraded' => '连接异常',
                          _ => account.status,
                        },
                        if (account.error != null) account.error!,
                      ].join(' · ')),
                      trailing: Wrap(spacing: 4, children: [
                        IconButton(
                          tooltip: '同步设备',
                          icon: const Icon(Icons.sync),
                          onPressed: _busy
                              ? null
                              : () => _ecosystem(() => widget.controller.smartHomeSync(account.accountId)),
                        ),
                        IconButton(
                          tooltip: '断开',
                          icon: const Icon(Icons.link_off),
                          onPressed: _busy
                              ? null
                              : () => _ecosystem(() => widget.controller.smartHomeUnbind(account.accountId)),
                        ),
                      ]),
                    ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _ecosystem(_connectAccount),
                    icon: const Icon(Icons.add_link),
                    label: const Text('连接平台'),
                  ),
                ],
              ],
            ]),
    );
  }
}
