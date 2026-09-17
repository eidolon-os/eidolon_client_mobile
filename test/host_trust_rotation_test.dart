import 'dart:collection';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:eidolon_client_mobile/src/features/host_setup/failure_sentences.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_locator.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_product_session.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/pinned_http_client.dart';
import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/controller_key_bridge.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/local_api_fixtures.dart';

const _controllerId = 'ectrl-0123456789abcdefabcd';
const _stalePin = 'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8';
const _rotatedPin = 'sha256:ckPDccJZ2vRCVPaJBsWCMlH8GWlrJsRifv7bkz09OA4';
const _uuid = 'f6a147b7-abef-57c3-973f-e3a17c6ef0ab';

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

dynamic _canonical(dynamic value) {
  if (value is Map<String, dynamic>) {
    final sorted = SplayTreeMap<String, dynamic>();
    for (final entry in value.entries) {
      sorted[entry.key] = _canonical(entry.value);
    }
    return sorted;
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

/// One Host's identity, and statements it can sign about its transport key.
class _Identity {
  _Identity(this.publicKey, this.hostId, this._pair);
  final String publicKey;
  final String hostId;
  final SimpleKeyPair _pair;

  static Future<_Identity> create(int seed) async {
    final pair = await Ed25519().newKeyPairFromSeed(List<int>.filled(32, seed));
    final public = await pair.extractPublicKey();
    final digest = crypto.sha256.convert(public.bytes).toString();
    return _Identity(_b64(public.bytes), 'ehost-${digest.substring(0, 20)}',
        pair);
  }

  Future<String> statement(String pin) async {
    final document = <String, dynamic>{
      'contract_version': '1',
      'purpose': 'eidolon-ble-commissioning-endpoint-v1',
      'host_public_key': publicKey,
      'reset_epoch': 0,
      'tls_spki_fingerprint': pin,
      'setup_session': null,
    };
    final signature = await Ed25519().sign(
      utf8.encode(jsonEncode(_canonical(document))),
      keyPair: _pair,
    );
    return jsonEncode({...document, 'signature': _b64(signature.bytes)});
  }
}

class _Discovery implements LocalApiDiscovery {
  @override
  Future<LocalApiSurvey> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      announcedSurvey([
        const LocalApiEndpoint(
          instanceName: 'Eidolon Local API on eidolon-pi5',
          baseUrl: 'https://192.168.100.15:9002',
          ipAddress: '192.168.100.15',
          contractVersion: '1',
        ),
      ]);
}

class _ControllerKeys implements ControllerKeyBridge {
  @override
  Future<ControllerIdentity> getIdentity() async => const ControllerIdentity(
        controllerId: _controllerId,
        publicKey: 'controller-public-key',
        fingerprint: 'sha256:controller',
      );
  @override
  Future<String> signChallenge(Map<String, dynamic> challenge) async => 'sig';
}

class _NoBle implements CommissioningTransport {
  @override
  Future<void> close() async {}
  @override
  Future<String> open({required String address, required String serviceUuid}) =>
      throw UnimplementedError();
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<Map<String, dynamic>> request(String o, Map<String, dynamic> p) =>
      throw UnimplementedError();
  @override
  Future<List<NearbyEidolonHost>> scan({
    required String serviceUuid,
    Duration timeout = const Duration(seconds: 8),
  }) async =>
      const [];
  @override
  Future<void> secure({required String tlsSpkiFingerprint}) =>
      throw UnimplementedError();
}

ManagedHost _host(_Identity identity) => ManagedHost(
      hostId: identity.hostId,
      hostPublicKey: identity.publicKey,
      hostFingerprint: 'sha256:unused',
      bleServiceUuid: _uuid,
      controllerId: _controllerId,
      displayName: 'Eidolon',
      claimedAt: DateTime.utc(2026, 8, 9),
      tlsSpkiFingerprint: _stalePin,
    );

/// Answers only to the pin the Host currently serves; the stale one is refused
/// exactly as the pinned transport refuses it.
LocalApiClientFactory _factoryServing(String servedPin, List<String> pinsTried) =>
    (pin) {
      pinsTried.add(pin);
      return LocalApiClient(
        httpClient: MockClient((request) async {
          if (pin != servedPin) {
            throw PinnedHttpException(
              kind: PinnedHttpFailureKind.secureChannel,
              message: 'Host TLS identity does not match its signed endpoint',
              observedSpkiFingerprint: servedPin,
            );
          }
          return http.Response('{}', 404);
        }),
      );
    };

void main() {
  test('a transport key this Host rotated is adopted without asking anyone',
      () async {
    final identity = await _Identity.create(7);
    final pins = <String>[];
    final session = HostProductSession(
      host: _host(identity),
      transport: _NoBle(),
      controllerKeys: _ControllerKeys(),
      discovery: _Discovery(),
      clientFactory: _factoryServing(_rotatedPin, pins),
      signedEndpointReader: (_, observed) => identity.statement(observed),
    );
    addTearDown(session.close);

    await expectLater(session.connect(), throwsA(isA<Object>()));

    expect(pins, contains(_stalePin), reason: 'the stored pin is tried first');
    expect(pins, contains(_rotatedPin),
        reason: 'the key the Host actually presented is adopted and re-dialled');
  });

  test('a statement signed by anyone else is not a rotation', () async {
    final paired = await _Identity.create(7);
    final stranger = await _Identity.create(9);
    final pins = <String>[];
    final session = HostProductSession(
      host: _host(paired),
      transport: _NoBle(),
      controllerKeys: _ControllerKeys(),
      discovery: _Discovery(),
      clientFactory: _factoryServing(_rotatedPin, pins),
      signedEndpointReader: (_, observed) => stranger.statement(observed),
    );
    addTearDown(session.close);

    await expectLater(session.connect(), throwsA(isA<HostLocationException>()));
    expect(pins, isNot(contains(_rotatedPin)),
        reason: 'an unsigned-for key is never adopted');
  });

  test('a statement naming a different key than the one speaking is refused',
      () async {
    final identity = await _Identity.create(7);
    final pins = <String>[];
    final session = HostProductSession(
      host: _host(identity),
      transport: _NoBle(),
      controllerKeys: _ControllerKeys(),
      discovery: _Discovery(),
      clientFactory: _factoryServing(_rotatedPin, pins),
      // Correctly signed, but about some other key: a replayed statement.
      signedEndpointReader: (_, __) => identity.statement(_stalePin),
    );
    addTearDown(session.close);

    await expectLater(session.connect(), throwsA(isA<HostLocationException>()));
    expect(pins, isNot(contains(_rotatedPin)));
  });

  test('a Host that is not the paired one is not offered a retry', () {
    final sentence = HostLocationException([
      HostCandidateFailure(
        const HostAddressCandidate(
          endpoint: LocalApiEndpoint(
            instanceName: 'x',
            baseUrl: 'https://192.168.100.19:9002',
            ipAddress: '192.168.100.19',
            contractVersion: '1',
          ),
          evidence: HostAddressEvidence.announced,
        ),
        PinnedHttpException(
          kind: PinnedHttpFailureKind.secureChannel,
          message: 'pin mismatch',
        ),
      ),
    ]).message;
    expect(sentence, contains('不是这台手机配对过的那一台'));
    expect(sentence, isNot(contains('重新查找')),
        reason: 'retrying cannot resolve a different Host');
  });

  test('a Host older than this build is named as that, not as a type error',
      () {
    final error = TypeError();
    expect(failureSentence(error), contains('版本'));
    expect(failureSentence(error), isNot(contains('subtype')));
  });

  test('a rotated pin is recorded, an identity that moved is refused', () async {
    // The last place that treated the pin as the identity. While it did, a
    // session could adopt a rotated key and the list would still show the
    // address and "last connected" from before the rotation, forever, because
    // the write carrying the new key was declined whole.
    final identity = await _Identity.create(7);
    final stored = _host(identity).copyWith(
      lastKnownBaseUrl: 'https://192.168.1.9:9002',
      lastConnectedAt: DateTime.utc(2026, 9, 10, 18, 26),
    );
    final registry = InMemoryHostRegistry([stored]);

    final rotated = await registry.updateObservation(stored.copyWith(
      tlsSpkiFingerprint: _rotatedPin,
      lastKnownBaseUrl: 'https://192.168.100.15:9002',
      lastConnectedAt: DateTime.utc(2026, 9, 18, 1, 39),
    ));
    expect(rotated?.tlsSpkiFingerprint, _rotatedPin);
    expect(rotated?.lastKnownBaseUrl, 'https://192.168.100.15:9002');
    expect(rotated?.lastConnectedAt, DateTime.utc(2026, 9, 18, 1, 39));

    final stranger = await _Identity.create(9);
    expect(
      await registry.updateObservation(ManagedHost(
        hostId: stored.hostId,
        hostPublicKey: stranger.publicKey,
        hostFingerprint: stored.hostFingerprint,
        bleServiceUuid: stored.bleServiceUuid,
        controllerId: stored.controllerId,
        displayName: stored.displayName,
        claimedAt: stored.claimedAt,
        tlsSpkiFingerprint: _rotatedPin,
      )),
      isNull,
      reason: 'an identity that moved is a different Host, not an observation',
    );
  });
}
