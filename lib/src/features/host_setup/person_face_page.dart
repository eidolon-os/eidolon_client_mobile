import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../management/management_client.dart';
import 'voiceprint_page.dart';
import 'face_picker.dart';

/// Which version of [faceRecognitionConsentStatement] the Owner agreed to.
const faceRecognitionConsentVersion = 'face-recognition-consent/2026-11-14';

/// The words shown in the consent step, sent to the Host exactly as shown.
const faceRecognitionConsentStatement =
    '我确认照片中的人已同意：Eidolon 从这张照片提取人脸特征并保存在本机 Host 上，'
    '用于在有摄像头的设备上认出并称呼 TA。识别结果只用于称呼，不是身份验证，'
    '也不会开放个人记忆。删除照片或关闭人脸识别会同时删除人脸特征。';

const _refreshAndRetry = '操作未确认，请刷新后重试';

/// Why the Host would not use this photo, keyed by its rejection reason.
const _photoRejections = <String, String>{
  'no_face': '照片里没有检测到人脸',
  'multiple_faces': '照片里有多张人脸，请换一张只有本人的照片',
  'face_too_small': '人脸太小，请换一张更近的正面照片',
  'low_confidence': '人脸不够清晰，请换一张照片',
};

/// What to say when turning recognition on or off was refused.
///
/// The client keeps only the refusal envelope (`kind`, `code`, `reason`), so
/// the rejection reason is looked for in both `code` and `reason`; a body that
/// carries it anywhere else reads as the generic sentence.
String faceRecognitionErrorText(Object error) {
  if (error is! ManagementRequestException) return _refreshAndRetry;
  final code = error.code;
  if (error.statusCode == 409 || error.someoneElseChangedIt) {
    return _refreshAndRetry;
  }
  if (error.statusCode == 503 || code == 'face_recognition_unavailable') {
    return 'Host 的人脸识别服务未运行，暂时无法启用';
  }
  if (error.statusCode == 422 || code == 'face_photo_rejected') {
    for (final text in [code, error.reason]) {
      if (text == null) continue;
      for (final entry in _photoRejections.entries) {
        if (text.contains(entry.key)) return entry.value;
      }
    }
    return '照片不适合用于识别';
  }
  return error.message;
}

/// Photo management, plus the separate consent step that turns recognition on.
/// Never chooses the current speaker.
class PersonFacePage extends StatefulWidget {
  const PersonFacePage(
      {super.key,
      required this.name,
      required this.active,
      required this.call,
      this.picker = const GalleryFacePicker()});
  final String name;
  final bool active;
  final VoiceprintCall call;
  final FacePicker picker;
  @override
  State<PersonFacePage> createState() => _PersonFacePageState();
}

class _PersonFacePageState extends State<PersonFacePage> {
  Map<String, dynamic>? _state;
  Uint8List? _image;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _act(_load);
  }

  bool get _hasImage => _state?['has_image'] == true;
  bool get _recognitionOn => _state?['recognition_state'] == 'enabled';

  Future<void> _act(Future<void> Function() action,
      {String Function(Object error)? describe}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted)
        setState(() => _error = describe != null
            ? describe(e)
            : e is ManagementRequestException
                ? e.message
                : _refreshAndRetry);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    final state = await widget.call();
    Uint8List? image;
    if (state['has_image'] == true) {
      final result = await widget.call(suffix: '/image');
      if (result['revision'] != state['revision'])
        throw StateError('Photo changed; refresh');
      image = base64Decode(result['image_base64'] as String);
    }
    if (mounted)
      setState(() {
        _state = state;
        _image = image;
      });
  }

  Future<void> _replace() => _act(() async {
        final bytes = await widget.picker.pickFace();
        if (bytes == null || !mounted) return;
        if (bytes.length > 1024 * 1024) {
          setState(() => _error = '请选择不超过 1 MiB 的照片');
          return;
        }
        try {
          await widget.call(method: 'PUT', body: {
            'expected_revision': _state!['revision'],
            'image_base64': base64Encode(bytes)
          });
        } finally {
          await _load();
        }
      });

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('删除人脸照片？'),
                content: const Text('只删除此用户的人脸照片，用户资料、声纹和个人记忆保留。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'))
                ]));
    if (confirmed != true || !mounted) return;
    await _act(() async {
      try {
        await widget.call(
            method: 'DELETE',
            suffix: '?expected_revision=${_state!['revision']}');
      } finally {
        await _load();
      }
    });
  }

  /// Sends one recognition change, then re-reads the state either way. A
  /// failed re-read must not replace the Host's refusal of the change itself.
  Future<void> _changeRecognition(Future<void> Function() change) =>
      _act(() async {
        try {
          await change();
        } catch (_) {
          try {
            await _load();
          } catch (_) {/* Keep the refusal; the refresh button remains. */}
          rethrow;
        }
        await _load();
      }, describe: faceRecognitionErrorText);

  Future<void> _enableRecognition() async {
    final confirmed = await showDialog<bool>(
        context: context, builder: (context) => const _ConsentDialog());
    if (confirmed != true || !mounted) return;
    await _changeRecognition(
        () => widget.call(method: 'PUT', suffix: '/recognition', body: {
              'expected_revision': _state!['revision'],
              'consent': {
                'consent_version': faceRecognitionConsentVersion,
                'statement': faceRecognitionConsentStatement,
                'attested': true
              }
            }));
  }

  Future<void> _disableRecognition() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('关闭人脸识别？'),
                content: const Text('关闭后会删除从照片提取的人脸特征，照片保留。之后可以重新启用。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('关闭'))
                ]));
    if (confirmed != true || !mounted) return;
    await _changeRecognition(
        () => widget.call(method: 'DELETE', suffix: '/recognition'));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text('${widget.name}的人脸档案'), actions: [
        IconButton(
            onPressed: _busy ? null : () => _act(_load),
            tooltip: '刷新',
            icon: const Icon(Icons.refresh))
      ]),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('保存此用户的照片后，可以另外启用人脸识别，让有摄像头的设备认出并称呼 TA。'
            '照片和人脸识别都不影响声纹识别或个人记忆。'),
        const SizedBox(height: 12),
        const Text('· 只有主人把摄像头设为「可拍照」的设备才会进行识别。\n'
            '· 识别结果只用于称呼，不是身份验证，也不会开放个人记忆。\n'
            '· 不认识的人，人脸不会被保存。\n'
            '· 更换或删除照片、关闭人脸识别，都会同时删除人脸特征。'),
        if (!widget.active)
          const Text('此用户已停用，仍可查看或删除照片、关闭人脸识别；启用后可更换照片或启用人脸识别。'),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 20),
        if (_state != null)
          Text(_recognitionOn
              ? '人脸识别已启用'
              : _hasImage
                  ? '照片已保存 · 人脸识别未启用'
                  : '尚未添加照片'),
        if (_image != null)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Image.memory(_image!,
                  height: 260, fit: BoxFit.contain, gaplessPlayback: false)),
        FilledButton.icon(
            onPressed:
                _busy || _state == null || !widget.active ? null : _replace,
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(_state?['has_image'] == true ? '更换照片' : '添加照片')),
        if (_state?['has_image'] == true)
          TextButton(
              onPressed: _busy ? null : _delete, child: const Text('删除照片')),
        const Divider(height: 32),
        if (_recognitionOn)
          OutlinedButton(
              onPressed: _busy ? null : _disableRecognition,
              child: const Text('关闭人脸识别'))
        else if (_state != null && !_hasImage)
          const Text('请先添加照片，再启用人脸识别。')
        else if (_state != null && widget.active)
          OutlinedButton(
              onPressed: _busy ? null : _enableRecognition,
              child: const Text('启用人脸识别')),
      ]));
}

/// The consent step: the statement, and a box that must be ticked to go on.
class _ConsentDialog extends StatefulWidget {
  const _ConsentDialog();
  @override
  State<_ConsentDialog> createState() => _ConsentDialogState();
}

class _ConsentDialogState extends State<_ConsentDialog> {
  bool _agreed = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
          scrollable: true,
          title: const Text('启用人脸识别？'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(faceRecognitionConsentStatement,
                key: Key('face-recognition-statement')),
            CheckboxListTile(
                key: const Key('face-recognition-agree'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('我已征得照片中本人的同意'),
                value: _agreed,
                onChanged: (value) => setState(() => _agreed = value == true)),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                key: const Key('face-recognition-confirm'),
                onPressed: _agreed ? () => Navigator.pop(context, true) : null,
                child: const Text('同意并启用'))
          ]);
}
