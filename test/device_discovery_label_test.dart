import 'package:flutter_test/flutter_test.dart';
import '../lib/src/features/device_setup/platform_device_provisioning.dart';

void main() {
  final label = provisioningDiscoveryLabel;
  test('old firmware remains identifiable and new firmware includes its model',
      () {
    expect(label('eidolon-7aef0c'), 'Eidolon 设备 · 7AEF0C');
    expect(label('eidolon-esp-box-3-52f354'), 'esp-box-3 · 52F354');
    expect(label('eidolon-touch-amoled-2.06-7aef0c'),
        'touch-amoled-2.06 · 7AEF0C');
    expect(label('eidolon-m5stack-stackchan-d84a04'),
        'm5stack-stackchan · D84A04');
    expect(label('Other device'), 'Other device');
  });
}
