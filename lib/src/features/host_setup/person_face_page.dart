import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../management/management_client.dart';
import 'voiceprint_page.dart';
import 'face_picker.dart';

/// Photo management only; never chooses the current speaker or enables recognition.
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

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted)
        setState(() => _error =
            e is ManagementRequestException ? e.message : '操作未确认，请刷新后重试');
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

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text('${widget.name}的人脸档案'), actions: [
        IconButton(
            onPressed: _busy ? null : () => _act(_load),
            tooltip: '刷新',
            icon: const Icon(Icons.refresh))
      ]),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('先保存此用户的照片，后续用于扩展人脸识别。当前尚未启用人脸识别，不影响声纹识别或个人记忆。'),
        if (!widget.active) const Text('此用户已停用，仍可查看或删除照片；启用后可更换。'),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 20),
        if (_state != null)
          Text(_state!['has_image'] == true ? '照片已保存 · 识别尚未启用' : '尚未添加照片'),
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
      ]));
}
