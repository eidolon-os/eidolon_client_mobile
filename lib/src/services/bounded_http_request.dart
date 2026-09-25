import 'package:http/http.dart' as http;

/// A unary request budget, carried locally rather than as a wire header.
/// Transports that support cancellation use the same budget as the caller.
class BoundedHttpRequest extends http.Request {
  BoundedHttpRequest(super.method, super.url, {required this.timeout});

  final Duration timeout;
}
