import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'host_product_session.dart';
import 'local_api_client.dart';
import 'pinned_http_client.dart';

/// Whether a failure says only that this phone did not reach the Host.
///
/// Silence, not an answer: nothing came back from the Host, so nothing is
/// known about it. After a visit to a device's access point that is the
/// ordinary state — the radio is the platform's to hand back, and the phone
/// may not be on the Host's network yet, or at all — and the move it calls
/// for is the person's (put the phone back on that network), not a retry of
/// the device. Everything the Host *said* is excluded: a refusal, a different
/// identity at an address this phone trusts, an answer it cannot read.
///
/// One definition, because two screens wait on it: the voucher asked for
/// between the two visits, and the Admission observed after the second.
bool hostNotReached(Object error) {
  if (error is PinnedHttpException) {
    return switch (error.kind) {
      PinnedHttpFailureKind.unreachable ||
      PinnedHttpFailureKind.timeout ||
      PinnedHttpFailureKind.io ||
      PinnedHttpFailureKind.cancelled =>
        true,
      _ => false,
    };
  }
  // Discovery candidates with another identity do not speak for the target.
  if (error is HostLocationException) {
    return error.targetFailures
        .every((failure) => hostNotReached(failure.error));
  }
  if (error is LocalApiRequestException) return false;
  // Re-authentication after a 401 has to reach the Host again, and the
  // network can go between the two requests; what failed then is the
  // network, which only the cause records.
  if (error is HostControllerAuthorizationException) {
    final cause = error.cause;
    return !error.reclaimRequired && cause != null && hostNotReached(cause);
  }
  return error is TimeoutException ||
      error is SocketException ||
      error is http.ClientException;
}
