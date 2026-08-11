import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'development_lan_commissioning.dart';
import 'host_registry.dart';
import 'setup_models.dart';

class DevelopmentLanSetupPage extends StatefulWidget {
  const DevelopmentLanSetupPage({super.key, required this.commissioning});

  final DevelopmentLanCommissioning commissioning;

  @override
  State<DevelopmentLanSetupPage> createState() =>
      _DevelopmentLanSetupPageState();
}

class _DevelopmentLanSetupPageState extends State<DevelopmentLanSetupPage> {
  final _setupCode = TextEditingController();
  final _controllerName = TextEditingController(text: '我的平板');
  List<DevelopmentLanHost> _hosts = const [];
  DevelopmentLanHost? _selected;
  bool _busy = false;
  String? _progress;
  String? _error;

  @override
  void dispose() {
    _setupCode.dispose();
    _controllerName.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    await _run(() async {
      setState(() => _progress = '正在通过 mDNS 查找已联网的开发 Host');
      final hosts = await widget.commissioning.discover();
      if (hosts.isEmpty) {
        throw const CommissioningRequestException(
          'host_not_found',
          '没有找到已生成有效 Setup 码的开发 Host',
        );
      }
      setState(() {
        _hosts = hosts;
        _progress = null;
      });
    });
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
    });
    try {
      await action();
    } on CommissioningRequestException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
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
              '仅限 Debug：mDNS 只发现候选，App 仍会验证 Host 签名并 pin TLS。'
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
            for (final host in _hosts)
              Card(
                child: ListTile(
                  selected: identical(_selected, host),
                  onTap: _busy ? null : () => setState(() => _selected = host),
                  leading: Icon(
                    identical(_selected, host)
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text(host.displayName),
                  subtitle: Text(
                    '${host.endpoint.hostId}\n${host.localApi.baseUrl}',
                  ),
                ),
              ),
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
            ],
          ],
        ),
      );
}
