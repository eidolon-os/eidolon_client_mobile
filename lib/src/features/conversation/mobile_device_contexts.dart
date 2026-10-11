import '../../platform/app_preferences.dart';
import '../../platform/platform_bridge.dart';
import '../device_setup/mobile_body_claim_store.dart';

/// One stable Device identity; authority references remain Owner scoped.
/// Each context captures its Claim store so late operations cannot write
/// another Host's authorization after a switch.
class MobileDeviceContext {
  const MobileDeviceContext(this.platform, this.claims);
  final PlatformBridge platform;
  final MobileBodyClaimStore claims;
}

class MobileDeviceContexts {
  MobileDeviceContexts({
    AppPreferences? preferences,
    PlatformBridge platform = const PlatformBridge(),
    MobileBodyClaimStore? legacyClaims,
  })  : _preferences = preferences ?? PlatformAppPreferences(),
        _platform = platform,
        _legacyClaims = legacyClaims ??
            PlatformMobileBodyClaimStore(preferences: preferences);

  final AppPreferences _preferences;
  final PlatformBridge _platform;
  final MobileBodyClaimStore _legacyClaims;
  static const _legacyOwnerKey = 'eidolon.legacy-device-owner.v1';

  Future<MobileDeviceContext> open(String ownerDomainId) {
    if (ownerDomainId.isEmpty) throw ArgumentError.value(ownerDomainId);
    return PreferenceWrites.run(_preferences, _legacyOwnerKey, () async {
      final identity = await _platform.getDeviceIdentity();
      final legacy = await _legacyClaims.loadFor(identity.operationalPublicKey);
      if (legacy != null) {
        final destination = PlatformMobileBodyClaimStore(
            preferences: _preferences, ownerDomainId: legacy.ownerDomainId);
        if (await destination.load() == null) await destination.save(legacy);
        // Persist the destination before retiring the old slot. An interrupted
        // migration retries without replacing a newer scoped Claim.
        await _legacyClaims.clear();
      }
      return MobileDeviceContext(
          _platform.forDevice(ownerDomainId),
          PlatformMobileBodyClaimStore(
              preferences: _preferences, ownerDomainId: ownerDomainId));
    });
  }
}
