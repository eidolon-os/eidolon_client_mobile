import 'dart:convert';
import 'dart:typed_data';

import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Reading and changing a face over the management contract.
///
/// The one thing on this surface measured in megabytes, over the one link that
/// is a house's wifi. So what these hold is the exchange that keeps it from
/// being paid twice: this app sends what it holds, and the Host answers "still
/// that one" with no body.

final _face = Uint8List.fromList([0xff, 0xd8, ...utf8.encode('a face'), 0xff, 0xd9]);
const _digest = 'e3b0c44298fc1c149afbf4c8996fb924';

void main() {
  test('the face arrives with the name of which face it is', () async {
    http.BaseRequest? sent;
    final client = ManagementClient(
      httpClient: MockClient((request) async {
        sent = request;
        return http.Response.bytes(
          _face,
          200,
          headers: {
            'content-type': 'image/jpeg',
            'etag': '"sha256:$_digest"',
          },
        );
      }),
    );

    final picture = await client.fetchCompanionFace(
      Uri.parse('https://192.168.1.26:9002'),
      accessToken: 'session-token',
      companionId: 'companion-a',
    );

    expect(sent?.url.path, '/api/management/v1/companions/companion-a/face');
    expect(sent?.headers.containsKey('If-None-Match'), isFalse);
    expect(picture.bytes, _face);
    // Carried on the answer, so nothing has to ask a second time which face it
    // just received — which is what the old two-call read was for.
    expect(picture.sha256, _digest);
  });

  test('the copy already held is not sent again', () async {
    String? asked;
    final client = ManagementClient(
      httpClient: MockClient((request) async {
        asked = request.headers['If-None-Match'];
        return http.Response('', 304);
      }),
    );
    final held = CompanionFacePicture(bytes: _face, sha256: _digest);

    final picture = await client.fetchCompanionFace(
      Uri.parse('https://192.168.1.26:9002'),
      accessToken: 'session-token',
      companionId: 'companion-a',
      held: held,
    );

    expect(asked, '"sha256:$_digest"');
    // The same picture, not a blank one: 304 means "what you have is current",
    // and dropping it here would blank a screen that was showing the right
    // thing.
    expect(identical(picture, held), isTrue);
  });

  test('an Eidolon with no face is a state, not a failure', () async {
    final client = ManagementClient(
      httpClient: MockClient((request) async => http.Response('', 204)),
    );

    final picture = await client.fetchCompanionFace(
      Uri.parse('https://192.168.1.26:9002'),
      accessToken: 'session-token',
      companionId: 'companion-a',
    );

    expect(picture.hasFace, isFalse);
    expect(picture.sha256, isNull);
  });

  test('the photograph is the body of the write, and refusals carry the reason',
      () async {
    http.Request? sent;
    var refuse = false;
    final client = ManagementClient(
      httpClient: MockClient((request) async {
        sent = request as http.Request;
        if (refuse) {
          return http.Response(
            jsonEncode({'detail': '这不是一张 JPEG'}),
            415,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'contract_version': '1',
            'companion_id': 'companion-a',
            'has_face': true,
            'sha256': _digest,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final stored = await client.setCompanionFace(
      Uri.parse('https://192.168.1.26:9002'),
      accessToken: 'session-token',
      companionId: 'companion-a',
      face: _face,
    );

    expect(sent?.method, 'PUT');
    expect(sent?.headers['Content-Type'], 'image/jpeg');
    expect(sent?.bodyBytes, _face);
    expect(stored.hasFace, isTrue);

    refuse = true;
    await expectLater(
      client.setCompanionFace(
        Uri.parse('https://192.168.1.26:9002'),
        accessToken: 'session-token',
        companionId: 'companion-a',
        face: _face,
      ),
      // Whether these bytes are a face is the Host's answer; this app relays
      // what it said rather than pre-judging it.
      throwsA(isA<ManagementRequestException>()
          .having((e) => e.statusCode, 'statusCode', 415)
          .having((e) => e.reason, 'reason', '这不是一张 JPEG')),
    );
  });
}
