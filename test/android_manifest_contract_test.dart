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

  // Admission stays screen-independent: whether a device is claimed is decided
  // on the Host, never by scanning anything. The camera reads only the setup
  // code a device shows while its setup window is open, and those eight digits
  // can always be typed instead — so no flow may require a camera, and nothing
  // may depend on Google Play services, which the HyperOS bench tablet lacks.
  test('a camera is optional and nothing depends on Play services', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final properties = File('android/gradle.properties').readAsStringSync();

    expect(
      manifest,
      contains(
          '<uses-feature android:name="android.hardware.camera" android:required="false" />'),
    );
    expect(manifest, isNot(contains('com.google.mlkit.vision.DEPENDENCIES')));
    expect(gradle, isNot(contains('play-services-code-scanner')));
    // mobile_scanner's unbundled mode downloads its model through Play services.
    expect(properties, isNot(contains('mobile_scanner.useUnbundled=true')));
  });
}
