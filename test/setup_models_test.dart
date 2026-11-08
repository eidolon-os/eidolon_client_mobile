import 'package:flutter_test/flutter_test.dart';

import 'package:eidolon_client_mobile/src/features/device_setup/platform_device_provisioning.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/setup_models.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';

/// The SDK's per-model setup declarations (DF-COMM-021), as this app ships
/// them: every name the app holds for a device finds its model, and the words
/// it shows say how that model opens setup mode.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the shipped catalog parses and names every model once', () async {
    final models = await loadSetupModels();
    expect(models.models, isNotEmpty);
    expect(models.models.map((m) => m.deviceKind).toSet(),
        containsAll(<String>{'esp-box-3', 'reachy-mini'}));
  });

  test('a SoftAP name and a Manifest id find the same model', () async {
    final models = await loadSetupModels();
    final box = models.forAdvertisedName('eidolon-esp-box-3-a1b2c3')!;
    expect(models.forManifestId('esp-box-3'), same(box));
    expect(box.setupCode, SetupCodePresentationV1.trustedDisplay);
    final reachy = models.forAdvertisedName('eidolon-reachy-f7dcb5')!;
    expect(models.forManifestId('eidolon-reachy-mini'), same(reachy));
    expect(reachy.setupCode, SetupCodePresentationV1.spokenCode);
    expect(models.forAdvertisedName('eidolon-unknown-a1b2c3'), isNull);
    expect(models.forManifestId(null), isNull);
  });

  test('the instruction says how to enter, and how to hear a spoken code again',
      () async {
    final models = await loadSetupModels();
    final box = setupModeInstruction(models.forManifestId('esp-box-3')!);
    expect(box, contains('BOOT'));
    expect(box, isNot(contains('念出')));
    final reachy =
        setupModeInstruction(models.forManifestId('eidolon-reachy-mini')!);
    expect(reachy, contains('天线'));
    expect(reachy, contains('念出 8 位设置码'));
  });

  test('a device in the list carries its model name', () async {
    final models = await loadSetupModels();
    expect(
      provisioningDiscoveryLabel('eidolon-reachy-f7dcb5',
          modelName: models.forAdvertisedName('eidolon-reachy-f7dcb5')?.name),
      'Reachy Mini · F7DCB5',
    );
  });

  test('a spoken code without a way to hear it again is refused', () {
    expect(
      () => SetupModelCatalogV1.fromJson({
        'catalog_version': '1',
        'models': [
          {
            'device_kind': 'reachy-mini',
            'ssid_model': 'reachy',
            'manifest_id': 'eidolon-reachy-mini',
            'name': 'Reachy Mini',
            'setup_code': 'spoken_code',
            'enter': '按住天线 3 秒。',
            'cancel': '再按住天线 3 秒。',
            'rehear': null,
          },
        ],
      }),
      throwsFormatException,
    );
  });
}
