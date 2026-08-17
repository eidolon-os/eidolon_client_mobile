import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// Where the picture an Eidolon wears comes from.
///
/// A port rather than a direct call into the plugin, for the same reason every
/// other platform capability in this app is one: a screen should be testable
/// without a gallery, and the gallery should be replaceable without touching
/// the screen.
abstract interface class FacePicker {
  /// The chosen picture, or null when the person changed their mind.
  Future<Uint8List?> pickFace();
}

class GalleryFacePicker implements FacePicker {
  const GalleryFacePicker();

  /// A face is a conditioning image for a digital human, not a photograph to
  /// keep. Asking the picker to bound it here means the camera's full
  /// resolution never has to be read into memory, sent over a transport that
  /// would refuse it, or stored on the Host to be scaled down later anyway.
  static const maximumEdge = 1024.0;
  static const quality = 85;

  @override
  Future<Uint8List?> pickFace() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: maximumEdge,
      maxHeight: maximumEdge,
      imageQuality: quality,
      requestFullMetadata: false,
    );
    return picked?.readAsBytes();
  }
}
