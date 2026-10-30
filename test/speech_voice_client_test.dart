import 'dart:convert';
import 'dart:typed_data';

import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Voices over the management contract: JSON one way, audio the other, and a
/// refusal said the same way for both.

final _host = Uri.parse('https://192.168.1.26:9002');
final _wav = Uint8List.fromList([...ascii.encode('RIFF'), 1, 2, 3, 4]);

/// UTF-8 on the wire, as the Host sends it: these answers carry Chinese.
http.Response _json(Object body, int status) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _companionVoice({String? key, int revision = 1}) => {
      'companion_id': 'companion-a',
      'revision': revision,
      if (key != null) 'selected_voice_key': key,
      'record_state': 'valid',
      'effective': {'display_name': '龙安洋', 'reason': 'unset'},
    };

void main() {
  test('a preview comes back as WAV bytes for the sample asked for', () async {
    http.Request? sent;
    final client = ManagementClient(httpClient: MockClient((request) async {
      sent = request;
      return http.Response.bytes(_wav, 200,
          headers: {'content-type': 'audio/wav'});
    }));

    final audio = await client.fetchVoicePreview(_host,
        accessToken: 't', voiceKey: 'c.abc', sample: 2);

    expect(sent!.url.path, '/api/management/v1/speech-voices/c.abc/preview');
    expect(sent!.url.queryParameters, {'sample': '2'});
    expect(sent!.headers['Authorization'], 'Bearer t');
    expect(audio, _wav);
  });

  test('going back to the Host voice sends no key at all', () async {
    http.Request? sent;
    final client = ManagementClient(httpClient: MockClient((request) async {
      sent = request;
      return _json(_companionVoice(revision: 2), 200);
    }));

    final view = await client.chooseCompanionSpeechVoice(_host,
        accessToken: 't',
        companionId: 'companion-a',
        choice: const SpeechVoiceChoice(expectedRevision: 1));

    expect(sent!.method, 'PUT');
    expect(sent!.url.path,
        '/api/management/v1/companions/companion-a/speech-voice');
    expect(jsonDecode(sent!.body), {'expected_revision': 1});
    expect(view.revision, 2);
  });

  test('a recording is sent as bytes, with the window asked for', () async {
    http.Request? sent;
    final client = ManagementClient(httpClient: MockClient((request) async {
      sent = request;
      return http.Response(
          jsonEncode({
            'accepted': true,
            'problems': [],
            'duration_ms': 30000,
            'window_start_ms': 5000,
            'window_ms': 20000,
            'audio_base64': base64Encode(_wav),
          }),
          200);
    }));

    final check = await client.checkVoiceReference(_host,
        accessToken: 't', audio: _wav, startMs: 5000);

    expect(sent!.url.path, '/api/management/v1/owner-voices/references/check');
    expect(sent!.url.queryParameters, {'start_ms': '5000'});
    expect(sent!.headers['Content-Type'], 'application/octet-stream');
    expect(sent!.bodyBytes, _wav);
    expect(check.accepted, isTrue);
    expect(check.windowStartMs, 5000);
  });

  test('deleting a voice expects nothing back', () async {
    http.Request? sent;
    final client = ManagementClient(httpClient: MockClient((request) async {
      sent = request;
      return http.Response('', 204);
    }));

    await client.deleteOwnerVoice(_host, accessToken: 't', voiceAssetId: 'v1');

    expect(sent!.method, 'DELETE');
    expect(sent!.url.path, '/api/management/v1/owner-voices/v1');
  });

  test('a refusal carries the Host sentence and its kind', () async {
    final client = ManagementClient(
        httpClient: MockClient((request) async => _json({
              'detail': {'kind': 'conflict', 'reason': '这个伙伴的声音刚被改过'}
            }, 409)));

    final failure = await client
        .chooseCompanionSpeechVoice(_host,
            accessToken: 't',
            companionId: 'companion-a',
            choice:
                const SpeechVoiceChoice(expectedRevision: 1, voiceKey: 'c.x'))
        .then<Object?>((_) => null, onError: (Object error) => error);

    expect(failure, isA<ManagementRequestException>());
    final refused = failure! as ManagementRequestException;
    expect(refused.statusCode, 409);
    expect(refused.someoneElseChangedIt, isTrue);
    expect(refused.reason, '这个伙伴的声音刚被改过');
  });

  test('a preview the Host could not make is a refusal, not audio', () async {
    final client = ManagementClient(
        httpClient: MockClient((request) async => _json({
              'detail': {'kind': 'not_found', 'reason': '这台主机没有这个声音'}
            }, 404)));

    await expectLater(
        client.fetchVoicePreview(_host, accessToken: 't', voiceKey: 'c.gone'),
        throwsA(isA<ManagementRequestException>()
            .having((e) => e.reason, 'reason', '这台主机没有这个声音')));
  });
}
