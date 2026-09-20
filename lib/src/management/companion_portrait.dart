import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'companion_preset_portrait.dart';
import 'management_client.dart';

typedef CompanionFaceLoader = Future<CompanionFacePicture> Function(
    {required String companionId});

/// One presentation policy for roster, detail, device choice and conversation.
/// Owner face wins; otherwise use the persisted, versioned official artwork.
/// Unknown artwork is deliberately rendered as an initial, never guessed from a name.
class CompanionPortrait extends StatefulWidget {
  const CompanionPortrait(
      {super.key,
      required this.companionId,
      required this.name,
      this.artworkId,
      this.face,
      this.loadFace,
      this.size = 48});
  final String companionId;
  final String name;
  final String? artworkId;
  final Uint8List? face;
  final CompanionFaceLoader? loadFace;
  final double size;
  @override
  State<CompanionPortrait> createState() => _CompanionPortraitState();
}

class _CompanionPortraitState extends State<CompanionPortrait> {
  Uint8List? _loaded;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CompanionPortrait oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.companionId != widget.companionId ||
        oldWidget.loadFace != widget.loadFace) {
      _loaded = null;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final loader = widget.loadFace;
    if (loader == null) return;
    try {
      final picture = await loader(companionId: widget.companionId);
      if (mounted && generation == _generation) {
        setState(() => _loaded = picture.bytes);
      }
    } catch (_) {
      // A missing/offline portrait must not block the companion or conversation.
    }
  }

  @override
  Widget build(BuildContext context) {
    final face = widget.face ?? _loaded;
    if (face != null) {
      return Semantics(
          image: true,
          label: '${widget.name}的角色形象',
          child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.memory(face,
                  width: widget.size,
                  height: widget.size,
                  fit: BoxFit.cover,
                  gaplessPlayback: false,
                  errorBuilder: (_, __, ___) => _artwork())));
    }
    return _artwork();
  }

  Widget _artwork() {
    const prefix = 'five-elements/1/';
    final id = widget.artworkId;
    return CompanionPresetPortrait(
        presetId: id != null && id.startsWith(prefix)
            ? id.substring(prefix.length)
            : '',
        name: widget.name,
        size: widget.size);
  }
}
