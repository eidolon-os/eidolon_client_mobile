import 'dart:collection';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';

/// A survey in which the service browse found these and the other probes were
/// not asked — the shape a test wants whenever what it is testing is what
/// happens *after* discovery.
LocalApiSurvey announcedSurvey(List<LocalApiEndpoint> endpoints) =>
    LocalApiSurvey([
      LocalApiSourceReport(
        origin: LocalApiCandidateOrigin.announced,
        attempted: '_eidolon-local-api._tcp',
        candidates: endpoints
            .map(
              (endpoint) => LocalApiCandidate(
                origin: LocalApiCandidateOrigin.announced,
                endpoint: endpoint,
              ),
            )
            .toList(growable: false),
      ),
    ]);

/// A Host endpoint document that actually verifies, signed here.
///
/// The frozen fixture cannot be varied — every field is inside the signature —
/// so anything that has to be tested *after* verification succeeds needs a
/// document this test suite can sign itself. A Host that is genuinely itself
/// and has no Setup session open is exactly that case.
Future<String> signedEndpointDocument({Object? setupSession}) async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(
    List<int>.filled(32, 7),
  );
  final publicKey = await keyPair.extractPublicKey();
  final document = <String, dynamic>{
    'contract_version': '1',
    'purpose': 'eidolon-ble-commissioning-endpoint-v1',
    'host_public_key': _base64Url(publicKey.bytes),
    'reset_epoch': 0,
    'tls_spki_fingerprint':
        'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8',
    'setup_session': setupSession,
  };
  final signature = await algorithm.sign(
    utf8.encode(jsonEncode(_canonical(document))),
    keyPair: keyPair,
  );
  return jsonEncode({...document, 'signature': _base64Url(signature.bytes)});
}

String _base64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

dynamic _canonical(dynamic value) {
  if (value is Map<String, dynamic>) {
    final sorted = SplayTreeMap<String, dynamic>();
    for (final entry in value.entries) {
      sorted[entry.key] = _canonical(entry.value);
    }
    return sorted;
  }
  if (value is List<dynamic>) {
    return value.map(_canonical).toList(growable: false);
  }
  return value;
}
