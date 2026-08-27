import 'package:http/http.dart' as http;

import 'local_api_client.dart';
import 'pinned_http_client.dart';

/// One place that turns a failure into a sentence a person can read.
///
/// Written because the raw form reached the screen. Taking the phone off
/// Wi-Fi mid-save produced:
///
///     没能保存：ClientException: Failed to connect to /192.168.3.206:9002,
///     uri=https://192.168.3.206:9002/api/local/v1/host
///
/// Two separate failures of care in one line. The exception's own `toString()`
/// is a developer artefact — a class name and a URL — and the URL is not even
/// the request the person asked for: the save re-resolves the Host first, so
/// what surfaced was a *precondition* whose path reads as though the product
/// were saving something called `host`. A person cannot act on either half.
///
/// The transports below already grade their own failures. This exists for the
/// last case — an ungraded error — where the honest thing is to say what is
/// true (the Host could not be reached) rather than to quote the machine.
String failureSentence(Object error) {
  if (error is PinnedHttpException) {
    return switch (error.kind) {
      PinnedHttpFailureKind.invalidRequest => 'App 无法构造有效的本地管理请求。',
      PinnedHttpFailureKind.unsupportedPlatform => '当前平台尚未实现安全的本地主机连接。',
      PinnedHttpFailureKind.secureChannel => '主机的加密身份与已保存身份不一致，已拒绝连接。',
      PinnedHttpFailureKind.timeout => '主机没有在预期时间内回应。',
      PinnedHttpFailureKind.unreachable => '当前网络到不了这台主机。',
      PinnedHttpFailureKind.io => '与主机的连接在中途断了。',
      PinnedHttpFailureKind.platform => '这台手机的安全连接组件暂时不可用。',
    };
  }
  if (error is LocalApiRequestException) {
    // The Host's own account of a refusal, when it wrote one.
    return error.reason ?? error.message;
  }
  if (error is http.ClientException) {
    // Deliberately says nothing about which request: an ungraded transport
    // failure often surfaces from a precondition call, and naming that URL
    // tells the person about a request they never made.
    return '到不了这台主机。';
  }
  // A sentence somebody already wrote, wrapped in the one thing Dart adds to
  // it. `Exception('附近没有等待设置的设备…').toString()` is that sentence with
  // `Exception: ` glued to the front, and that prefix is how a written-for-a-
  // person line came to read as a crash on the device setup screen.
  final text = error.toString();
  const wrapper = 'Exception: ';
  if (text.startsWith(wrapper) && text.length > wrapper.length) {
    return text.substring(wrapper.length);
  }
  return '这台手机没能完成这次操作。';
}
