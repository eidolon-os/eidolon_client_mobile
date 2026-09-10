import 'package:eidolon_client_mobile/src/features/host_setup/network_changes.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('route changes reach all consumers even when both networks are Wi-Fi',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const name = 'live.eidolon.mobile/network-changes';
    const channel = MethodChannel(name);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var listens = 0;
    var cancels = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listen') listens++;
      if (call.method == 'cancel') cancels++;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final list = PlatformNetworkChanges();
    final connection = PlatformNetworkChanges();
    var listEvents = 0;
    var connectionEvents = 0;
    final a = list.changes.listen((_) => listEvents++);
    final b = connection.changes.listen((_) => connectionEvents++);
    await Future<void>.delayed(Duration.zero);
    Future<void> moved(String route) async {
      await messenger.handlePlatformMessage(name,
          const StandardMethodCodec().encodeSuccessEnvelope(route), (_) {});
      await Future<void>.delayed(Duration.zero);
    }

    await moved('101:wlan0:192.168.1.9/24');
    await moved('102:wlan0:10.0.0.9/24');
    expect(listEvents, 2);
    expect(connectionEvents, 2);
    expect(listens, 1);
    await a.cancel();
    await list.close();
    await moved('102:wlan0:10.0.0.10/24');
    expect(connectionEvents, 3);
    expect(cancels, 0);
    await b.cancel();
    await connection.close();
    expect(cancels, 1);
  });
}
