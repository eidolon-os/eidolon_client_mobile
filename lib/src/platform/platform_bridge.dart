import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/hub_models.dart';

class PlatformBridge {
  const PlatformBridge();

  static const _channel = MethodChannel('live.eidolon.mobile/platform');

  Future<DeviceIdentity> getDeviceIdentity() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'getDeviceIdentity',
    );
    if (result == null) {
      throw StateError('Platform did not return a device identity');
    }
    return DeviceIdentity.fromMap(result);
  }

  Future<SignedRequest> signRequest({
    required String method,
    required String pathQuery,
    required String body,
  }) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'signRequest',
      {'method': method, 'pathQuery': pathQuery, 'body': body},
    );
    if (result == null) {
      throw StateError('Platform did not return signed headers');
    }
    return SignedRequest.fromMap(result);
  }

  /// Sign [document] with this device's operational key, as ES256 `r || s`.
  ///
  /// [document] must already be canonical — see
  /// `protocol/canonical_json.dart`, which is where this app's one RFC 8785
  /// implementation lives and where the vectors that pin it are applied. The
  /// platform signs the bytes it is given and never re-encodes them.
  ///
  /// Which key signs is deliberately not a parameter: the operational key and
  /// the Controller key say different things to a Host, and a caller that could
  /// pick between them could sign an enrollment with the Controller's identity.
  Future<String> signDeviceCanonicalDocument(String document) async {
    final signature = await _channel.invokeMethod<String>(
      'signDeviceCanonicalDocument',
      {'document': document},
    );
    if (signature == null || signature.isEmpty) {
      throw StateError('Platform did not return a signature');
    }
    return signature;
  }

  /// Mint the one-shot key this enrollment's ClaimGrant will be sealed to.
  ///
  /// The private half stays on the platform. What comes back is what the
  /// proposal carries, what the returned envelope will name, and a handle to
  /// present when the Grant arrives.
  Future<PlatformHandoffKey> issueHandoffKey() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'issueHandoffKey',
    );
    if (result == null) {
      throw StateError('Platform did not return a handoff key');
    }
    return PlatformHandoffKey.fromMap(result);
  }

  /// Open a ClaimGrant envelope with the handoff key [handle] addresses.
  ///
  /// [encapsulatedKey] and [ciphertext] are passed through exactly as the
  /// envelope carries them — base64url — because re-encoding a value on its way
  /// to being authenticated is a way to change it. [aad] is the canonical JSON
  /// this side produced; only its encoding for transport happens here.
  ///
  /// Throws if the key is gone. That is not the same failure as a Grant that
  /// does not authenticate, and the platform keeps them apart: one is
  /// recoverable by cancelling and proposing again, the other means the Grant
  /// was addressed to somebody else.
  Future<Uint8List> openClaimGrant({
    required String handle,
    required String encapsulatedKey,
    required String aad,
    required String ciphertext,
  }) async {
    final plaintext = await _channel.invokeMethod<String>(
      'openClaimGrant',
      {
        'handle': handle,
        'encapsulatedKey': encapsulatedKey,
        'aad': base64Url.encode(utf8.encode(aad)).replaceAll('=', ''),
        'ciphertext': ciphertext,
      },
    );
    if (plaintext == null) {
      throw StateError('Platform did not return a ClaimGrant');
    }
    return Uint8List.fromList(
      base64Url.decode(
        plaintext.padRight(plaintext.length + (-plaintext.length % 4), '='),
      ),
    );
  }

  /// Prove possession of this enrollment's handoff key over [document].
  ///
  /// [document] must already be canonical. Collection is refused by the
  /// Authority without this proof, and it must be made by the handoff key
  /// rather than the operational one — the Authority verifies it against the
  /// SPKI the proposal carried.
  Future<String> signHandoffCanonicalDocument({
    required String handle,
    required String document,
  }) async {
    final signature = await _channel.invokeMethod<String>(
      'signHandoffCanonicalDocument',
      {'handle': handle, 'document': document},
    );
    if (signature == null || signature.isEmpty) {
      throw StateError('Platform did not return a handoff key proof');
    }
    return signature;
  }

  /// Whether this process still holds a handoff key.
  ///
  /// The one question that tells an approved Enrollment apart from an approved
  /// Enrollment nobody can finish. The key lives only in memory, so after a
  /// restart the answer is no and the Grant waiting at the Authority can never
  /// be opened — by this phone or anyone. A screen that cannot ask this would
  /// keep saying 「正在领取归属凭证」 about a collection that is not happening.
  Future<bool> holdsHandoffKey() async =>
      await _channel.invokeMethod<bool>('holdsHandoffKey') ?? false;

  /// Forget the handoff key once its one shot is spent, or abandoned.
  Future<void> discardHandoffKey() async {
    await _channel.invokeMethod<bool>('discardHandoffKey');
  }

  Future<bool> requestMicrophonePermission() async =>
      await _channel.invokeMethod<bool>('requestMicrophonePermission') ?? false;

  Future<bool> playIdentifyFeedback() async {
    await HapticFeedback.heavyImpact();
    await SystemSound.play(SystemSoundType.alert);
    return true;
  }

  Future<bool> playWiggleFeedback() async {
    await HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await HapticFeedback.mediumImpact();
    await SystemSound.play(SystemSoundType.click);
    return true;
  }
}

/// The public half of one enrollment's handoff key, as the platform issued it.
///
/// A platform-boundary value, defined next to its only producer. It is not a
/// Hub model: nothing here has been near a Hub yet, and the proposal that will
/// carry [publicKey] has not been made.
class PlatformHandoffKey {
  const PlatformHandoffKey({
    required this.handle,
    required this.publicKey,
    required this.keyId,
  });

  /// Addresses the private half, which never leaves the platform.
  final String handle;

  /// `p256-spki:<base64url>`, as `CreateEnrollment.handoff_key.public_key`.
  final String publicKey;

  /// `sha256:<hex>`, which the returned envelope names as
  /// `recipient_handoff_key_id`. Compared, never recomputed on this side.
  final String keyId;

  factory PlatformHandoffKey.fromMap(Map<Object?, Object?> value) {
    final handle = value['handle'];
    final publicKey = value['publicKey'];
    final keyId = value['keyId'];
    if (handle is! String ||
        handle.isEmpty ||
        publicKey is! String ||
        !publicKey.startsWith('p256-spki:') ||
        keyId is! String ||
        !keyId.startsWith('sha256:')) {
      throw const FormatException('Platform returned an unusable handoff key');
    }
    return PlatformHandoffKey(
      handle: handle,
      publicKey: publicKey,
      keyId: keyId,
    );
  }
}
