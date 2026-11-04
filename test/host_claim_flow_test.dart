import 'package:eidolon_client_mobile/src/features/setup/host_claim_flow.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_claim_pake.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_pake_host.dart';

const _code = '40718256';
const _commissioningId = '3f6b8a62-0c1e-4b8e-9a51-2d7c4e9f1a03';
const _hostKey = 'nlnBLOE0I5iIzTmR6qrVcmsObSBI5JGFoWzYbtMqG7w';
const _tls = 'sha256:pdIu6eJ7FLJf5gVXsFbxXZRr0xCGGtuqKb1zJvauNaw';

const _expected = HostClaimExpectation(
  hostPublicKey: _hostKey,
  tlsSpkiFingerprint: _tls,
  resetEpoch: 2,
  commissioningId: _commissioningId,
  transport: 'ble',
  controllerPublicKey: fakeControllerPublicKey,
);

FakePakeHost _host({String code = _code}) => FakePakeHost(
      code: code,
      commissioningId: _commissioningId,
      hostPublicKey: _hostKey,
      tlsSpkiFingerprint: _tls,
      resetEpoch: 2,
      transport: 'ble',
    );

Future<HostClaimProof> _direct(HostClaimProofRequest request) async =>
    proveHostClaim(request);

Future<Map<String, dynamic>?> _run(
  FakePakeHost host, {
  String code = _code,
  bool hostPredatesPake = false,
  int forgetHandshakes = 0,
}) {
  var forgotten = 0;
  return proveSetupCodeToHost(
    code: code,
    expected: _expected,
    start: (payload) async => hostPredatesPake ? null : host.start(payload),
    confirm: (payload) async {
      if (forgotten < forgetHandshakes) {
        forgotten += 1;
        throw const CommissioningRequestException(
            'pake_handshake_unknown', 'Start the Setup code exchange again');
      }
      return {
        'server_proof': host.confirm(payload),
        'state': {'claim_state': 'unclaimed'},
      };
    },
    prove: _direct,
  );
}

void main() {
  test('the right code proves both sides and nothing carries the code', () async {
    final host = _host();
    final sent = <Map<String, dynamic>>[];
    final result = await proveSetupCodeToHost(
      code: _code,
      expected: _expected,
      start: (payload) async {
        sent.add(payload);
        return host.start(payload);
      },
      confirm: (payload) async {
        sent.add(payload);
        return {'server_proof': host.confirm(payload)};
      },
      prove: _direct,
    );
    expect(result, isNotNull);
    expect(host.confirmedControllerKeys, hasLength(1));
    expect(sent.toString(), isNot(contains('setup_code')));
    expect(sent.toString(), isNot(contains(_code)));
    expect(sent.toString(), isNot(contains(hostClaimPassword(_code))));
  });

  test('a wrong code is the Host refusing, not the Host failing to prove',
      () async {
    await expectLater(
      _run(_host(), code: '00000012'),
      throwsA(isA<CommissioningRequestException>()
          .having((e) => e.code, 'code', 'commissioning_denied')),
    );
  });

  test('a Host naming other keys than the pinned ones gets no proof at all',
      () async {
    for (final (field, value) in [
      ('tls', 'sha256:${'A' * 43}'),
      ('host', 'B' * 43),
    ]) {
      final standIn = _host();
      if (field == 'tls') standIn.tlsSpkiFingerprint = value;
      if (field == 'host') standIn.hostPublicKey = value;
      await expectLater(
        _run(standIn),
        throwsA(isA<CommissioningRequestException>()
            .having((e) => e.code, 'code', 'host_identity_mismatch')),
      );
      expect(standIn.confirms, 0, reason: field);
    }
  });

  test('a Host that cannot prove the code back is not believed', () async {
    final standIn = _host()..lieAboutServerProof = true;
    await expectLater(
      _run(standIn),
      throwsA(isA<CommissioningRequestException>()
          .having((e) => e.code, 'code', 'host_not_proven')),
    );
  });

  test('a Host before the PAKE is reported, not guessed at', () async {
    final host = _host();
    expect(await _run(host, hostPredatesPake: true), isNull);
    expect(host.starts, 0);
  });

  test('a forgotten handshake is started again once, then reported', () async {
    final host = _host();
    expect(await _run(host, forgetHandshakes: 1), isNotNull);
    expect(host.starts, 2);
    await expectLater(
      _run(_host(), forgetHandshakes: 2),
      throwsA(isA<CommissioningRequestException>()
          .having((e) => e.code, 'code', 'pake_handshake_unknown')),
    );
  });

  test('a malformed B is the Host failing to prove, before anything is sent',
      () async {
    var confirms = 0;
    await expectLater(
      proveSetupCodeToHost(
        code: _code,
        expected: _expected,
        start: (payload) async {
          final started = _host().start(payload);
          return {...started, 'B': base64UrlNoPad(List<int>.filled(384, 0))};
        },
        confirm: (payload) async {
          confirms += 1;
          return {};
        },
        prove: _direct,
      ),
      throwsA(isA<CommissioningRequestException>()
          .having((e) => e.code, 'code', 'host_not_proven')),
    );
    expect(confirms, 0);
  });
}
