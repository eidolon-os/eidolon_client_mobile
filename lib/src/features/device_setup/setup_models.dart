import 'dart:convert';

import 'package:flutter/services.dart';

import '../../generated/device_foundation_v1.dart';

/// How each device model enters and leaves setup mode and gives its setup code,
/// as the SDK declares it (`models/setup.json`), vendored by the SDK lock.
const setupModelsAsset = 'assets/device_foundation/setup-models.json';

/// Read once, the first time a screen asks; every screen shares it.
final Future<SetupModelCatalogV1> setupModels = loadSetupModels();

Future<SetupModelCatalogV1> loadSetupModels([AssetBundle? bundle]) async =>
    SetupModelCatalogV1.fromJson(
      jsonDecode(await (bundle ?? rootBundle).loadString(setupModelsAsset))
          as Map<String, dynamic>,
    );

/// How a person opens setup mode at one model, and hears its code again if it
/// speaks it. Whole sentences, for after whatever the screen said first.
String setupModeInstruction(SetupModelV1 model) {
  final rehear = model.rehear;
  return '${model.name} 进入配网模式的方法：${model.enter}'
      '${rehear == null ? '' : '它会念出 8 位设置码，没听清就$rehear'}';
}
