import 'package:flutter/material.dart';
import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import 'voiceprint_page.dart';

/// Companion-level policy lives here; recording and profile management have their own pages.
class CompanionVoiceAccess extends StatefulWidget {
  const CompanionVoiceAccess(
      {super.key, required this.companionName, required this.call, this.hold});
  final String companionName;
  final VoiceprintCall call;
  final String? hold;
  @override
  State<CompanionVoiceAccess> createState() => _CompanionVoiceAccessState();
}

class _CompanionVoiceAccessState extends State<CompanionVoiceAccess> {
  VoicePolicyView? _policy;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    if (widget.hold == null) _load();
  }

  @override
  void didUpdateWidget(covariant CompanionVoiceAccess oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hold != null && widget.hold == null) _load();
  }

  Future<void> _load() => _request(() => widget.call());
  Future<void> _request(Future<Map<String, dynamic>> Function() call) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final policy = VoicePolicyView.fromJson(await call());
      if (mounted) setState(() => _policy = policy);
    } catch (e) {
      if (mounted)
        setState(() => _error =
            e is ManagementRequestException ? e.message : '无法读取声纹设置，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manage() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => VoiceprintPage(
            companionName: widget.companionName, call: widget.call)));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final policy = _policy;
    final allowed = policy?.allowedProfileIds?.length ?? 0;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('声纹识别',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                if (widget.hold != null)
                  Text(widget.hold!)
                else ...[
                  if (_busy) const LinearProgressIndicator(),
                  if (policy != null)
                    SwitchListTile(
                      key: const Key('companion-voiceprint-switch'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('仅回应已录入的声音'),
                      subtitle: Text(policy.mode == 'allowlist'
                          ? (allowed == 0
                              ? '暂无允许的声音，当前不会回应语音'
                              : '已开启 · 允许 $allowed 个声音，其他声音不触发对话')
                          : '未开启 · 对话不受声纹限制'),
                      value: policy.mode == 'allowlist',
                      onChanged: _busy
                          ? null
                          : (value) => _request(() => widget.call(
                              method: 'PUT',
                              suffix: '/policy',
                              body: PolicyUpdate(
                                      expectedRevision: policy.revision ?? 0,
                                      mode: value ? 'allowlist' : 'off')
                                  .toJson())),
                    ),
                  if (_error != null) ...[
                    Text(_error!),
                    TextButton(
                        onPressed: _busy ? null : _load,
                        child: const Text('重试'))
                  ],
                  TextButton.icon(
                    key: const Key('companion-open-voiceprints'),
                    onPressed: _busy ? null : _manage,
                    icon: const Icon(Icons.record_voice_over),
                    label: Text(policy == null
                        ? '管理声纹'
                        : '管理声纹 · 已录入 ${policy.profiles?.length ?? 0} 个，允许 $allowed 个'),
                  ),
                ],
              ],
            )));
  }
}
