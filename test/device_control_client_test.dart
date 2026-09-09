import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:eidolon_client_mobile/src/features/conversation/device_control_client.dart';
import 'package:eidolon_client_mobile/src/protocol/livekit_session_binding.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/admission_fixtures.dart';

/// The edge where a Body learns whether it still is one, and where it may talk.
///
/// Both answers belong to the Authority, and the interesting assertions here
/// are about the ones a client is tempted to supply for itself: a revocation
/// read as a failure, a missing channel read as a reason, an answer to an older
/// ask read as an answer to this one.
///
/// The signing document is `DF-DEVICE-CONTROL-CONFIGURATION-PROOF-001`. It had
/// no vector for a while, and the assertion that stood in for one rebuilt the
/// expected bytes with `canonicalJsonEncode` — the same encoder the code under
/// test uses — so it agreed with the producer by construction and could not
/// fail on a changed member set. The vector is read now.
Map<String, dynamic> _responses() => jsonDecode(
      File('test/fixtures/device_foundation/'
              'device-control-configuration-response.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;

Map<String, dynamic> _vector() => jsonDecode(
      File('test/fixtures/device_foundation/'
              'device-control-configuration-proof.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;

void main() {
  Map<String, Object?> deviceRef() => Map<String, Object?>.from(
        canonicalContractValue('DF-ADMISSION-CLAIM-GRANT-VALID')['device_ref']!
            as Map,
      );

  String sealSession({
    String serverUrl = 'wss://livekit.owner-domain.invalid',
  }) =>
      base64.encode(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'schema_version': 2,
            'session': <String, Object?>{
              'server_url': serverUrl,
              'token': 'a.jwt.token',
              'identity': 'device-instance-${'a' * 64}',
              'room_name': 'eidolon-0123456789abcdef01234567',
            },
            'audio': <String, Object?>{'sample_rate': 16000, 'channels': 1},
          }),
        ),
      );

  /// An answer, and [ref] is the ref the Authority says it holds.
  ///
  /// Defaulted rather than echoed, because the whole point of the member is
  /// that it may differ from the one the request carried.
  Map<String, Object?> answer({
    required String nonce,
    String lifecycle = 'approved',
    List<Object?>? channels,
    Map<String, Object?>? ref,
  }) =>
      <String, Object?>{
        'operation': 'device-control.configuration',
        'nonce': nonce,
        'device_ref': ref ?? deviceRef(),
        'lifecycle_state': lifecycle,
        'manifest': null,
        'channels': channels ?? const <Object?>[],
      };

  http.Response ok(Object? body) => http.Response(
        jsonEncode(body),
        200,
        headers: const {'content-type': 'application/json'},
      );

  DeviceControlClient client(MockClient transport, {String? nonce}) =>
      DeviceControlClient(
        authority: Uri.parse('https://hub.owner-domain.invalid'),
        transport: transport,
        // Overridden only where the vector's own nonce is needed. Everywhere
        // else the real generator runs, including in the test that checks its
        // shape.
        newNonce: nonce == null ? null : () => nonce,
      );

  test('the signed request is the bytes the vector pins', () async {
    final vector = _vector();
    final document = vector['document']! as Map<String, dynamic>;

    late Map<String, dynamic> sent;
    late String signed;
    // Every input from the vector, not from a local helper: the vector's
    // `device_ref` carries `claim_generation: 7` and `trust_epoch: 4`, values
    // this file's own fixture does not, and taking the inputs from here while
    // taking only the expectation from there is how a test named for a golden
    // never disagrees with one.
    final flow = client(
      MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        // About the device the request named. This test sends the proof
        // vector's `device_ref` and the helper's default is the Claim Grant
        // fixture's — a different `device_instance_id` — and an answer about
        // another device is now refused, correctly, before any of the byte
        // comparisons below could run.
        return ok(answer(
          nonce: sent['nonce']! as String,
          ref: Map<String, Object?>.from(sent['device_ref']! as Map),
        ));
      }),
      nonce: document['nonce']! as String,
    );

    await flow.pullConfiguration(
      deviceRef: Map<String, Object?>.from(document['device_ref']! as Map),
      operationalPublicKey: vector['public_key_spki']! as String,
      sign: (canonical) async {
        signed = canonical;
        return vector['signature']! as String;
      },
    );

    expect(signed, vector['canonical_utf8']);
    expect(
      'sha256:${sha256.convert(utf8.encode(signed))}',
      vector['canonical_sha256'],
    );
    // The signing key the vector names. Signing this with the handoff key
    // would be a device asking about a Claim it is not the subject of, and no
    // byte comparison above would notice.
    expect(vector['signing_key'], 'operational');
    // The envelope is this client's, not the vector's — the vector pins the
    // document that is signed, and the four members that carry it are the
    // request contract.
    expect(sent.keys.toSet(), <String>{
      'device_ref',
      'nonce',
      'public_key_spki',
      'device_signature',
    });
  });

  test('every member the vector says must not move is in the signed bytes',
      () {
    // A dropped member is invisible to the byte comparison above, which passes
    // for the vector's own values; it is only visible as an absence.
    final vector = _vector();
    final signed = jsonDecode(vector['canonical_utf8']! as String);
    for (final path in (vector['mutate_each_field_must_fail']! as List<Object?>)
        .cast<String>()) {
      Object? value = signed;
      for (final segment in path.split('.')) {
        expect(value, isA<Map<String, dynamic>>(), reason: path);
        final map = value! as Map<String, dynamic>;
        expect(map.containsKey(segment), isTrue, reason: '$path is absent');
        value = map[segment];
      }
    }
  });

  test('each answer the vector pins leads to the conclusion it names',
      () async {
    // `configuration:pull`'s outer answer, against the contract's own three
    // cases. The distinction this pins is the one §4.3 records the product
    // having already collapsed once: approved-with-no-channel is neither an
    // error nor a revocation, and a Body that reads it as either abandons an
    // enrolment that is fine or joins a room that does not exist.
    final vector = _responses();
    final expected = <String, ({bool stands, bool session})>{
      'DF-DEVICE-CONTROL-CONFIGURATION-ACTIVE': (stands: true, session: true),
      'DF-DEVICE-CONTROL-CONFIGURATION-APPROVED-AWAITING-CHANNEL':
          (stands: true, session: false),
      'DF-DEVICE-CONTROL-CONFIGURATION-REVOKED':
          (stands: false, session: false),
    };

    for (final entry in (vector['cases']! as List<Object?>)
        .cast<Map<String, dynamic>>()) {
      final caseId = entry['case_id']! as String;
      final want = expected[caseId];
      expect(want, isNotNull, reason: 'the vector grew a case: $caseId');

      final configuration = await client(
        MockClient((_) async => ok(entry['response'])),
        nonce: vector['request_nonce']! as String,
      ).pullConfiguration(
        deviceRef: Map<String, Object?>.from(vector['device_ref']! as Map),
        operationalPublicKey: 'p256-spki:AAAA',
        sign: (_) async => 'x' * 86,
      );

      expect(configuration.claimStands, want!.stands, reason: caseId);
      expect(configuration.session != null, want.session, reason: caseId);
    }
  });

  test('every answer the vector says must be refused is refused', () async {
    // Four of them, and all four carry the right nonce on purpose — so the
    // echo check this client already had catches none of them. What each one
    // withholds is different, and the point of the set is that a Body cannot
    // pass by getting one right.
    final vector = _responses();
    final refusals = (vector['must_refuse']! as List<Object?>)
        .cast<Map<String, dynamic>>();

    expect(refusals, hasLength(4));
    // The vector publishes the rule now, and it is the one this client uses.
    // It is asserted rather than assumed because the alternative reading —
    // judging expiry against the reader's clock — passes every case here by
    // accident on the day a vector is written and fails them all later.
    expect(vector['expiry_is_not_judged_against'], "the reader's clock");
    for (final entry in refusals) {
      await expectLater(
        client(
          MockClient((_) async => ok(entry['response'])),
          nonce: vector['request_nonce']! as String,
        ).pullConfiguration(
          deviceRef: Map<String, Object?>.from(vector['device_ref']! as Map),
          operationalPublicKey: 'p256-spki:AAAA',
          sign: (_) async => 'x' * 86,
        ),
        throwsA(isA<DeviceControlRefusal>()),
        reason: entry['case_id'] as String,
      );
    }
  });

  test('a delivered channel becomes a room this device may join', () async {
    final flow = client(MockClient((request) async {
      final nonce =
          (jsonDecode(request.body) as Map<String, dynamic>)['nonce']! as String;
      return ok(answer(nonce: nonce, channels: <Object?>[
        <String, Object?>{
          'channel_id': 'channel_01',
          'purpose': 'conversation',
          'kinds': <String>['audio'],
          'binding_format': liveKitSessionBindingFormat,
          'issued_at_ms': 1,
          'expires_at_ms': 2,
          'opaque_binding': sealSession(),
        },
      ]));
    }));

    final configuration = await flow.pullConfiguration(
      deviceRef: deviceRef(),
      operationalPublicKey: 'p256-spki:AAAA',
      sign: (_) async => 'x' * 86,
    );

    expect(configuration.claimStands, isTrue);
    expect(configuration.session!.serverUrl, 'wss://livekit.owner-domain.invalid');
    expect(configuration.session!.usable, isTrue);
  });

  test('revoked is an answer, not a failure', () async {
    // This is the edge where a device finds out. Revocation happens between
    // the Owner and the Authority, and nothing local can tell the phone — so
    // a client that raised here would turn the one delivery of that news into
    // an error to be retried.
    final flow = client(MockClient((request) async {
      final nonce =
          (jsonDecode(request.body) as Map<String, dynamic>)['nonce']! as String;
      return ok(answer(nonce: nonce, lifecycle: 'revoked'));
    }));

    final configuration = await flow.pullConfiguration(
      deviceRef: deviceRef(),
      operationalPublicKey: 'p256-spki:AAAA',
      sign: (_) async => 'x' * 86,
    );

    expect(configuration.claimStands, isFalse);
    expect(configuration.session, isNull);
  });

  test('no channel yet is not a reason, and not an error', () async {
    // An active Claim with no channel is what a phone sees while one is being
    // provisioned — and also what it sees when provisioning refused. The
    // Authority returns the same thing either way, so this side must not
    // invent which.
    final flow = client(MockClient((request) async {
      final nonce =
          (jsonDecode(request.body) as Map<String, dynamic>)['nonce']! as String;
      return ok(answer(nonce: nonce));
    }));

    final configuration = await flow.pullConfiguration(
      deviceRef: deviceRef(),
      operationalPublicKey: 'p256-spki:AAAA',
      sign: (_) async => 'x' * 86,
    );

    expect(configuration.claimStands, isTrue);
    expect(configuration.session, isNull);
  });

  test('the answered ref is the one the Authority holds, not the one asked with',
      () async {
    // The recovery this closes. A Body whose stored ref fell behind its own
    // Claim — the Owner re-added an already-claimed device, so Admission
    // upserted the Claim at the next `claim_generation` — used to match no
    // Claim at all and be refused 409 forever: every retry carried the same
    // stale ref, so nothing the device could do on its own ended it. The
    // Authority finds the Claim by identity now and answers with the ref it
    // actually holds, and this answer is the only place a phone can learn
    // what moved.
    final held = deviceRef()
      ..['owner_domain_generation'] = 4
      ..['claim_generation'] = 9
      ..['trust_epoch'] = 5;
    final flow = client(MockClient((request) async {
      final nonce =
          (jsonDecode(request.body) as Map<String, dynamic>)['nonce']! as String;
      return ok(answer(nonce: nonce, ref: held));
    }));

    final configuration = await flow.pullConfiguration(
      // Still the stale one. A device that knew the answer would not need it.
      deviceRef: deviceRef(),
      operationalPublicKey: 'p256-spki:AAAA',
      sign: (_) async => 'x' * 86,
    );

    // Carried whole, because that is how it is stored and how the next ask is
    // addressed: a ref rebuilt from the members this build happens to know
    // would be a different document at the far end.
    expect(configuration.deviceRef, held);
    expect(configuration.claimStands, isTrue);
  });

  test('a revocation still says which ref it was about', () async {
    // Revoked is an answer, and it answers with a ref like every other. The
    // interesting part is that this one is not a correction to act on — the
    // caller drops the record instead — so the member exists here without
    // being a re-pin.
    final flow = client(MockClient((request) async {
      final nonce =
          (jsonDecode(request.body) as Map<String, dynamic>)['nonce']! as String;
      return ok(answer(nonce: nonce, lifecycle: 'revoked'));
    }));

    final configuration = await flow.pullConfiguration(
      deviceRef: deviceRef(),
      operationalPublicKey: 'p256-spki:AAAA',
      sign: (_) async => 'x' * 86,
    );

    expect(configuration.claimStands, isFalse);
    expect(configuration.deviceRef, deviceRef());
  });

  test('an answer about another device is not a correction', () async {
    // A moved generation is a correction. A moved identity is a different
    // device's configuration wearing this ask's nonce, and the two must not
    // land in the same place: this one is refused the way an unreadable answer
    // is, rather than written over the Claim this phone holds. Only the
    // generations may move.
    for (final foreign in <Map<String, Object?>>[
      deviceRef()..['device_instance_id'] = 'device-instance-${'b' * 64}',
      deviceRef()..['owner_domain_id'] = 'owner-domain_99',
    ]) {
      final flow = client(MockClient((request) async {
        final nonce = (jsonDecode(request.body)
            as Map<String, dynamic>)['nonce']! as String;
        return ok(answer(nonce: nonce, ref: foreign));
      }));

      await expectLater(
        flow.pullConfiguration(
          deviceRef: deviceRef(),
          operationalPublicKey: 'p256-spki:AAAA',
          sign: (_) async => 'x' * 86,
        ),
        throwsA(
          isA<DeviceControlRefusal>()
              .having((error) => error.detail, 'detail', contains('another device'))
              .having((error) => error.retryable, 'retryable', isFalse),
        ),
        reason: 'accepted an answer about ${foreign['device_instance_id']} '
            'in ${foreign['owner_domain_id']}',
      );
    }
  });

  test('a ref this build cannot read is refused rather than stored', () async {
    // The generations are the two members a stored Claim is only useful for,
    // and `MobileBodyClaimRecord.fromJson` discards a record missing either —
    // silently, on the next read. So an answer that cannot supply them is
    // refused here: accepting it would have a phone forget a Claim it holds
    // and present itself as never enrolled.
    for (final unreadable in <Object?>[
      null,
      'device-instance-x',
      deviceRef()..remove('claim_generation'),
      deviceRef()..['trust_epoch'] = 'four',
    ]) {
      final flow = client(MockClient((request) async {
        final nonce = (jsonDecode(request.body)
            as Map<String, dynamic>)['nonce']! as String;
        return ok(<String, Object?>{
          'operation': 'device-control.configuration',
          'nonce': nonce,
          'device_ref': unreadable,
          'lifecycle_state': 'approved',
          'manifest': null,
          'channels': const <Object?>[],
        });
      }));

      await expectLater(
        flow.pullConfiguration(
          deviceRef: deviceRef(),
          operationalPublicKey: 'p256-spki:AAAA',
          sign: (_) async => 'x' * 86,
        ),
        throwsA(isA<DeviceControlRefusal>()),
        reason: 'read $unreadable as a DeviceRef',
      );
    }
  });

  test('an answer to a different ask is refused', () async {
    // The nonce comes back so this can be checked. An answer about an older
    // ask could report a Claim that has since been revoked.
    final flow = client(MockClient((_) async => ok(answer(nonce: 'somebody-elses-nonce'))));

    await expectLater(
      flow.pullConfiguration(
        deviceRef: deviceRef(),
        operationalPublicKey: 'p256-spki:AAAA',
        sign: (_) async => 'x' * 86,
      ),
      throwsA(
        isA<DeviceControlRefusal>().having(
          (error) => error.detail,
          'detail',
          contains('different request'),
        ),
      ),
    );
  });

  test('a rejected proof is not worth asking again with', () async {
    // 403 and 409 are answers about this device. Retrying with the same facts
    // produces the same answer, and a client that retried would be the
    // 「立即检查状态」 button in another place.
    for (final status in const [403, 409]) {
      final flow = client(
        MockClient((_) async => http.Response(
              jsonEncode(<String, Object?>{'detail': 'device proof rejected'}),
              status,
            )),
      );

      await expectLater(
        flow.pullConfiguration(
          deviceRef: deviceRef(),
          operationalPublicKey: 'p256-spki:AAAA',
          sign: (_) async => 'x' * 86,
        ),
        throwsA(
          isA<DeviceControlRefusal>()
              .having((error) => error.retryable, 'retryable', isFalse)
              .having((error) => error.status, 'status', status),
        ),
      );
    }
  });

  test('a server fault is worth asking again with', () async {
    final flow = client(MockClient((_) async => http.Response('nope', 503)));

    await expectLater(
      flow.pullConfiguration(
        deviceRef: deviceRef(),
        operationalPublicKey: 'p256-spki:AAAA',
        sign: (_) async => 'x' * 86,
      ),
      throwsA(
        isA<DeviceControlRefusal>()
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('a nonce is fresh, and shaped the way the contract accepts', () async {
    // `^[A-Za-z0-9_-]{16,128}$`. Its whole job is to make one answer belong to
    // one ask, so a repeat would defeat the check above.
    final seen = <String>{};
    final flow = client(MockClient((request) async {
      final nonce =
          (jsonDecode(request.body) as Map<String, dynamic>)['nonce']! as String;
      seen.add(nonce);
      expect(RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(nonce), isTrue);
      return ok(answer(nonce: nonce));
    }));

    for (var index = 0; index < 8; index += 1) {
      await flow.pullConfiguration(
        deviceRef: deviceRef(),
        operationalPublicKey: 'p256-spki:AAAA',
        sign: (_) async => 'x' * 86,
      );
    }

    expect(seen, hasLength(8));
  });
}
