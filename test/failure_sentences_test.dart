import 'package:eidolon_client_mobile/src/features/host_setup/failure_sentences.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/pinned_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  _wrappedSentences();
  test('an ungraded transport failure never quotes the machine', () {
    // The exact shape that reached a real screen: a save that first
    // re-resolves the Host, failing on that precondition.
    final sentence = failureSentence(
      http.ClientException(
        'Failed to connect to /192.168.3.206:9002',
        Uri.parse('https://192.168.3.206:9002/api/local/v1/host'),
      ),
    );
    expect(sentence, '到不了这台主机。');
    // Neither the class name, nor the address, nor a path the person did not
    // ask for.
    expect(sentence, isNot(contains('ClientException')));
    expect(sentence, isNot(contains('192.168')));
    expect(sentence, isNot(contains('/api/')));
  });

  test('the Host keeps the last word when it wrote one', () {
    expect(
      failureSentence(
        const LocalApiRequestException(
          'x 返回 HTTP 404',
          statusCode: 404,
          reason: '主机上已经没有这台设备了。',
        ),
      ),
      '主机上已经没有这台设备了。',
    );
    expect(
      failureSentence(const LocalApiRequestException('主机没有回应')),
      '主机没有回应',
    );
  });

  test('every graded transport failure has its own sentence', () {
    final sentences = <String>{};
    for (final kind in PinnedHttpFailureKind.values) {
      final sentence = failureSentence(
        PinnedHttpException(kind: kind, message: 'raw'),
      );
      expect(sentence, isNot(contains('raw')));
      sentences.add(sentence);
    }
    // Distinct: collapsing "this network cannot reach it" into "the Host
    // refused your identity" is how a fixable problem reads as a broken one.
    expect(sentences.length, PinnedHttpFailureKind.values.length);
  });

  test('an error nobody graded still reads as a sentence', () {
    expect(failureSentence(StateError('boom')), '这台手机没能完成这次操作。');
  });
}

void _wrappedSentences() {
  test('a sentence somebody wrote survives the wrapper Dart glues on', () {
    expect(
      failureSentence(
        Exception('附近没有等待设置的设备。请按一下设备上的按键让它进入设置模式，然后重试。'),
      ),
      '附近没有等待设置的设备。请按一下设备上的按键让它进入设置模式，然后重试。',
    );
  });
}
