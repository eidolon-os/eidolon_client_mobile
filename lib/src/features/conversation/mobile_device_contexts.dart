import '../../platform/app_preferences.dart';
import '../../platform/platform_bridge.dart';
import '../device_setup/mobile_body_claim_store.dart';

/// One standard Device per Owner Domain, independent of Host routes and App
/// Controller identity. A scope is bound into its key adapter and Claim store;
/// late operations cannot follow a mutable "current Host" into another Owner.
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
      var legacyOwner = await _preferences.readString(_legacyOwnerKey);
      if (legacyOwner == null) {
        // Existing installs keep their key and Claim. With no saved Claim,
        // assign the legacy key once to preserve any unfinished enrollment at
        // the first verified Owner. Never reassign it after revoke or restart.
        legacyOwner = legacy?.ownerDomainId ?? ownerDomainId;
        await _preferences.writeString(_legacyOwnerKey, legacyOwner);
      }
      if (legacy != null) {
        if (legacy.ownerDomainId != legacyOwner) {
          throw const FormatException(
              'Legacy Device owner changed after migration');
        }
        final destination = PlatformMobileBodyClaimStore(
            preferences: _preferences, ownerDomainId: legacyOwner);
        if (await destination.load() == null) await destination.save(legacy);
        // Persist the destination before retiring the old slot. An interrupted
        // migration retries without replacing a newer scoped Claim.
        await _legacyClaims.clear();
      }
      return MobileDeviceContext(
          legacyOwner == ownerDomainId
              ? _platform
              : _platform.forDevice(ownerDomainId),
          PlatformMobileBodyClaimStore(
              preferences: _preferences, ownerDomainId: ownerDomainId));
    });
  }
}
