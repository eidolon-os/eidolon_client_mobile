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
      if (mounted) {
        setState(() => _error = e is ManagementRequestException
            ? (e.reason ?? e.message)
            : '无法读取声纹设置，请重试');
      }
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

  Future<void> _setMode(VoicePolicyView policy, bool enabled) =>
      _request(() => widget.call(
          method: 'PUT',
          suffix: '/policy',
          body: PolicyUpdate(
                  expectedRevision: policy.revision ?? 0,
                  mode: enabled ? 'allowlist' : 'off')
              .toJson()));

  @override
  Widget build(BuildContext context) {
    final policy = _policy;
    final allowed = policy?.allowedProfileIds?.length ?? 0;
    final limits = policy?.readiness?.limits;
    final overLimit = limits != null && allowed > limits.maxAllowedSpeakers;
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
                  if (limits != null) ...[
                    Text(
                        '当前最多 ${limits.maxAllowedSpeakers} 个声音；每句 ${_seconds(limits.minAudioMs)}–${_seconds(limits.maxAudioMs)} 秒。'),
                    if (overLimit)
                      Text('已选择 $allowed 个声音，超过当前范围；请在管理声纹中移除多余的允许项。录音不需要删除。'),
                  ],
                  if (policy?.readiness?.validationState == 'controlled_trial')
                    const Text('受控测试 · 尚未校准，阈值为临时假设。仅用于本轮对话验收，不代表正式识别准确率。'),
                  if (policy != null)
                    SwitchListTile(
                      key: const Key('companion-voiceprint-switch'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('仅回应已录入的声音'),
                      subtitle: Text(policy.mode == 'allowlist'
                          ? (policy.readiness?.admissionReady != true
                              ? '限制已开启，但识别服务未就绪；语音暂无法通过验证。可以关闭限制。'
                              : policy.admissionState != 'ready'
                                  ? '声音列表或识别版本已变化，请重新确认。确认前不会接纳语音。'
                                  : '已开启 · 允许 $allowed 个声音。通过验证后才打断和回复；不分离重叠人声。更改后请重新进入对话。')
                          : policy.readiness?.admissionReady != true
                              ? '识别能力验证中 · 尚不可开启限制'
                              : '未开启 · 对话不受声纹限制。更改后请重新进入对话。'),
                      value: policy.mode == 'allowlist',
                      onChanged: _busy ||
                              (policy.mode != 'allowlist' &&
                                  (policy.readiness?.admissionReady != true ||
                                      overLimit ||
                                      allowed == 0))
                          ? null
                          : (value) => _setMode(policy, value),
                    ),
                  if (policy?.mode == 'allowlist' &&
                      policy?.readiness?.admissionReady == true &&
                      policy?.admissionState != 'ready')
                    TextButton(
                        onPressed: _busy || overLimit || allowed == 0
                            ? null
                            : () => _setMode(policy!, true),
                        child: const Text('重新确认允许的声音')),
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

String _seconds(int? milliseconds) =>
    ((milliseconds ?? 0) / 1000).toString().replaceFirst(RegExp(r'\.0$'), '');
