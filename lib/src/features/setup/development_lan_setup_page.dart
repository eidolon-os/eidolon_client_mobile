import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../host_setup/local_api_discovery.dart';
import 'development_lan_commissioning.dart';
import 'host_registry.dart';
import 'host_discovery_sections.dart';
import 'setup_models.dart';

class DevelopmentLanSetupPage extends StatefulWidget {
  const DevelopmentLanSetupPage(
      {super.key, required this.commissioning, this.registry});

  final DevelopmentLanCommissioning commissioning;
  final HostRegistry? registry;

  @override
  State<DevelopmentLanSetupPage> createState() =>
      _DevelopmentLanSetupPageState();
}

class _DevelopmentLanSetupPageState extends State<DevelopmentLanSetupPage> {
  final _setupCode = TextEditingController();
  final _controllerName = TextEditingController(text: '我的平板');
  List<DevelopmentLanHost> _hosts = const [];
  List<ManagedHost> _knownHosts = const [];
  DevelopmentLanHost? _selected;
  bool _busy = false;
  String? _progress;
  String? _error;

  /// Why the last attempt failed, when the Host said something this page can
  /// act on. A message can only be read; a code can put the way out on screen.
  String? _errorCode;

  @override
  void dispose() {
    _setupCode.dispose();
    _controllerName.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    await _run(() async {
      setState(
        () {
          _hosts = const [];
          _selected = null;
          _setupCode.clear();
          _progress = '正在同时用 mDNS 服务浏览、主机名解析和本网段探测查找开发 Host';
        },
      );
      _knownHosts = await widget.registry?.load() ?? [];
      if (!mounted) return;
      final discovered =
          await widget.commissioning.discover(knownHosts: _knownHosts);
      if (!mounted) return;
      // The report already knows which of the several ways this can come up
      // empty happened, and what to do about each; the page must not flatten
      // that back into one sentence.
      final failure = discovered.failure;
      if (failure != null) throw failure;
      setState(() {
        _hosts = discovered.hosts;
        _progress = null;
      });
    });
  }

  ManagedHost? _known(DevelopmentLanHost host) =>
      knownHostForEndpoint(_knownHosts, host.endpoint);

  void _select(DevelopmentLanHost host) {
    final known = _known(host);
    if (known != null) {
      Navigator.of(context).pop<ManagedHost>(known);
    } else {
      setState(() => _selected = host);
    }
  }

  Future<void> _claim() async {
    final selected = _selected;
    if (selected == null) return;
    await _run(() async {
      setState(() => _progress = '正在验证 Host 签名、TLS pin 和 Setup 码');
      final host = await widget.commissioning.claim(
        selected,
        setupCode: _setupCode.text.trim(),
        controllerName: _controllerName.text,
      );
      if (mounted) Navigator.of(context).pop<ManagedHost>(host);
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _errorCode = null;
    });
    try {
      await action();
    } on CommissioningRequestException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _errorCode = error.code;
          _progress = null;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = '开发 Host 接入失败：$error';
          _progress = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('局域网开发 Host')),
        body: ListView(
          key: const Key('development-lan-setup-page'),
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              '仅限 Debug：mDNS 服务浏览、主机名解析和本网段探测都只发现候选，'
              'App 仍会验证 Host 签名并 pin TLS。'
              '请先在 Host 上生成短期 $setupCodeDigits 位 Setup 码。',
            ),
            const SizedBox(height: 16),
            if (_hosts.isEmpty)
              FilledButton.icon(
                key: const Key('discover-development-lan-hosts'),
                onPressed: _busy ? null : _discover,
                icon: const Icon(Icons.lan_outlined),
                label: const Text('查找开发 Host'),
              ),
            HostDiscoverySections(
              available: [
                for (final host in _hosts)
                  if (_known(host) == null) _buildHost(host),
              ],
              added: [
                for (final host in _hosts)
                  if (_known(host) != null) _buildHost(host),
              ],
            ),
            if (_hosts.isNotEmpty) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('rescan-development-lan-hosts'),
                onPressed: _busy ? null : _discover,
                icon: const Icon(Icons.refresh),
                label: const Text('重新扫描'),
              ),
            ],
            if (_selected != null) ...[
              const SizedBox(height: 16),
              TextField(
                key: const Key('development-lan-setup-code'),
                controller: _setupCode,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(setupCodeDigits),
                ],
                maxLength: setupCodeDigits,
                decoration: const InputDecoration(
                  labelText: '$setupCodeDigits 位 Setup 码',
                  counterText: '',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('development-lan-controller-name'),
                controller: _controllerName,
                decoration: const InputDecoration(
                  labelText: '管理设备名称',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('claim-development-lan-host'),
                onPressed: _busy ? null : _claim,
                icon: const Icon(Icons.verified_user_outlined),
                label: const Text('安全认领此 Host'),
              ),
            ],
            if (_progress != null) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                  key: const Key('development-lan-progress')),
              const SizedBox(height: 8),
              Text(_progress!),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                key: const Key('development-lan-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              // A Host that will never carry this entrance leaves this page
              // with nothing left to try, and 「查找开发 Host」 above would only
              // fail the same way again. The other door is one pop back, so
              // put it here rather than describing where it is.
              if (_errorCode == 'development_lan_entrance_absent') ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('development-lan-use-bluetooth'),
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).pop<ManagedHost>(),
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('回到蓝牙设置'),
                ),
              ],
            ],
          ],
        ),
      );

  Widget _buildHost(DevelopmentLanHost host) {
    final known = _known(host);
    return Card(
      child: ListTile(
        selected: identical(_selected, host),
        onTap: _busy ? null : () => _select(host),
        leading: const Icon(Icons.memory),
        title: Text(known?.displayName ?? host.displayName),
        trailing: TextButton(
          onPressed: _busy ? null : () => _select(host),
          child: Text(known == null ? '添加' : '连接'),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (known != null) const Text('已添加'),
            Text('${host.endpoint.hostId}\n${host.localApi.baseUrl}'
                '（${host.candidate.origin.label}）'),
          ],
        ),
      ),
    );
  }
}
