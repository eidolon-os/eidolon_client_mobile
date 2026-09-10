import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/development_lan_commissioning.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';

class EmptyLocalApiDiscovery implements LocalApiDiscovery {
  @override
  Future<LocalApiSurvey> discover(
          {Duration timeout = const Duration(seconds: 5)}) async =>
      const LocalApiSurvey([]);
}

DevelopmentLanCommissioning emptyLanCommissioning() =>
    DevelopmentLanCommissioning(discovery: EmptyLocalApiDiscovery());

class UnavailableBleTransport implements CommissioningTransport {
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<void> close() async {}
  @override
  Future<List<NearbyEidolonHost>> scan(
          {required String serviceUuid,
          Duration timeout = const Duration(seconds: 8)}) =>
      throw StateError('No BLE permission');
  @override
  Future<String> open({required String address, required String serviceUuid}) =>
      throw StateError('No BLE permission');
  @override
  Future<void> secure({required String tlsSpkiFingerprint}) =>
      throw StateError('No BLE permission');
  @override
  Future<Map<String, dynamic>> request(
          String operation, Map<String, dynamic> payload) =>
      throw StateError('No BLE permission');
}
