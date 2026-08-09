import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device hotspot transport declares Android network permissions', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    for (final permission in [
      'android.permission.INTERNET',
      'android.permission.ACCESS_NETWORK_STATE',
      'android.permission.CHANGE_NETWORK_STATE',
      'android.permission.ACCESS_WIFI_STATE',
      'android.permission.CHANGE_WIFI_STATE',
      'android.permission.NEARBY_WIFI_DEVICES',
    ]) {
      expect(
        manifest,
        contains('android:name="$permission"'),
        reason: 'Missing permission required by the device hotspot transport',
      );
    }
  });

  test('system QR scanner is preloaded without requesting camera permission',
      () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();

    expect(manifest, isNot(contains('android.permission.CAMERA')));
    expect(manifest, contains('com.google.mlkit.vision.DEPENDENCIES'));
    expect(manifest, contains('android:value="barcode_ui"'));
    expect(
      gradle,
      contains('play-services-code-scanner:16.1.0'),
    );
  });
}
