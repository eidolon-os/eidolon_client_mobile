import 'dart:io';

import 'package:eidolon_client_mobile/src/avatar/idle_clip_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('downloads signed idle clip once for local looping', () async {
    final directory =
        await Directory.systemTemp.createTemp('eidolon-idle-test-');
    addTearDown(() => directory.delete(recursive: true));

    var requests = 0;
    final client = MockClient((request) async {
      requests += 1;
      expect(request.url.toString(), 'http://hub.local/api/avatar/idle/video');
      expect(request.headers['x-device-nonce'], 'one-shot-nonce');
      return http.Response.bytes([0, 1, 2, 3], HttpStatus.ok);
    });
    final cache = IdleClipCache(
      client: client,
      cacheDirectory: directory,
    );
    addTearDown(cache.close);

    final file = await cache.download(
      url: 'http://hub.local/api/avatar/idle/video',
      headersProvider: () async => {
        'X-Device-Nonce': 'one-shot-nonce',
      },
    );

    expect(requests, 1);
    expect(await file.readAsBytes(), [0, 1, 2, 3]);
  });

  test('does not create a playable file for a hub error', () async {
    final directory =
        await Directory.systemTemp.createTemp('eidolon-idle-test-');
    addTearDown(() => directory.delete(recursive: true));

    final cache = IdleClipCache(
      client: MockClient((_) async => http.Response('replayed nonce', 409)),
      cacheDirectory: directory,
    );
    addTearDown(cache.close);

    expect(
      () => cache.download(
        url: 'http://hub.local/api/avatar/idle/video',
        headersProvider: () async => const {},
      ),
      throwsA(isA<HttpException>()),
    );
  });
}
