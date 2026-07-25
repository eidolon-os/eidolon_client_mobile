import 'dart:io';

import 'package:http/http.dart' as http;

typedef IdleClipHeadersProvider = Future<Map<String, String>> Function();

/// Downloads a signed idle clip once and stores it in the app's temporary
/// directory.
///
/// Hub signatures use one-shot anti-replay nonces. Feeding the signed URL
/// directly to ExoPlayer is unsafe because looping/probing can issue another
/// HTTP request with the same headers. Playing this local file keeps every
/// signed nonce single-use.
class IdleClipCache {
  IdleClipCache({
    http.Client? client,
    Directory? cacheDirectory,
  })  : _client = client ?? http.Client(),
        _cacheDirectory = cacheDirectory ?? Directory.systemTemp;

  final http.Client _client;
  final Directory _cacheDirectory;

  Future<File> download({
    required String url,
    required IdleClipHeadersProvider headersProvider,
  }) async {
    final uri = Uri.parse(url);
    final headers = await headersProvider();
    final response = await _client.get(uri, headers: headers);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Idle clip request failed with HTTP ${response.statusCode}',
        uri: uri,
      );
    }

    await _cacheDirectory.create(recursive: true);
    final cacheKey = url.hashCode.toUnsigned(32).toRadixString(16);
    final file = File('${_cacheDirectory.path}/eidolon-idle-$cacheKey.mp4');
    await file.writeAsBytes(response.bodyBytes, flush: true);
    return file;
  }

  void close() => _client.close();
}
