import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/device_setup/device_instance_identity.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/platform/platform_bridge.dart';

/// A phone identity shaped the way the Android half actually answers.
///
/// The fake it replaces returned a ready-made `device-instance-<64hex>` as the
/// platform's `deviceId`, which no build of this app has ever done: Android
/// answered with an ANDROID_ID-derived `mobile-android-<hash>`, and every test
/// that mattered passed against an identity the product could not produce.
///
/// So the fake now answers with a *key*, and the derivation runs for real. A
/// fake proves a caller behaves correctly given an answer; it must at least be
/// giving the shape of answer that exists.
///
/// The key is the SDK's own commissioning vector, so the id below is a number
/// from the contract rather than one invented here.
const phoneOperationalPublicKey =
    'p256-spki:MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaxfR8uEsQkf4vOblY6RA8ncDf'
    'YEt6zOg9KE5RdiYwpZP40Li_hp_m47n60p8D54WK84zV2sxXs7LtkBoN79R9Q';

/// The id Hub would derive for [phoneOperationalPublicKey], and the only id
/// this phone may claim.
final phoneDeviceInstanceId =
    deriveDeviceInstanceId(phoneOperationalPublicKey);

const phoneInstallId = 'mobile-android-dcaa15ac8c09efa36c97825ad21bec49';

const phoneFingerprint =
    'p256:5cd252fb0ce8932436faf8ccd1040981b89ee4ad6b9fe9e2a2b7e71aacb27cd3';

class FakePhonePlatform extends PlatformBridge {
  /// A signature of the right shape, over whatever it was given.
  ///
  /// 64 bytes as base64url, because that is what every consumer checks: the
  /// evidence assembler refuses any other length and the Authority's contract
  /// pins the field at 86 characters. What it does *not* do is sign — a test
  /// that cares which bytes were signed asserts the document it was handed,
  /// which is the half this fake cannot fake.
  @override
  Future<String> signDeviceCanonicalDocument(String document) async =>
      base64Url.encode(List<int>.filled(64, 7)).replaceAll('=', '');

  /// No handoff key, because none was ever minted here.
  ///
  /// The honest default for a fake phone: a key exists only after a proposal
  /// mints one, and a fake that claimed to hold one would let a test assert
  /// that an Enrollment can be finished when nothing could finish it.
  @override
  Future<bool> holdsHandoffKey() async => false;

  @override
  Future<DeviceIdentity> getDeviceIdentity() async => const DeviceIdentity(
        installId: phoneInstallId,
        operationalPublicKey: phoneOperationalPublicKey,
        fingerprint: phoneFingerprint,
      );
}
