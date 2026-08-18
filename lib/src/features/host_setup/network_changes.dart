import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// When this phone's own network changed.
///
/// Not a reachability check and not a claim about the Host: the Host may be
/// exactly where it was. What changed is that this phone can no longer assume
/// the address it last used is still the way there — a different Wi-Fi, a
/// switch to cellular, or a cable that went away.
///
/// An interface rather than the plugin, so the session boundary that consumes
/// it stays testable without a platform channel, in the same shape as
/// [LocalApiDiscovery] and the commissioning transport.
abstract interface class NetworkChanges {
  Stream<void> get changes;

  Future<void> close();
}

/// The real thing, on top of connectivity_plus.
///
/// Every transition is reported, including the ones that look like nothing:
/// Wi-Fi to Wi-Fi is the case that matters most, because it is the one where
/// the old address stays syntactically valid and simply stops leading
/// anywhere.
class PlatformNetworkChanges implements NetworkChanges {
  PlatformNetworkChanges({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;
  StreamController<void>? _controller;
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  @override
  Stream<void> get changes {
    final existing = _controller;
    if (existing != null) return existing.stream;
    final controller = StreamController<void>.broadcast();
    _controller = controller;
    _subscription = _connectivity.onConnectivityChanged.listen(
      (_) => controller.add(null),
      // A phone that stops reporting its own connectivity is not a reason to
      // take down the screen watching it: the reactive path still recovers
      // from an address that stopped working, this only removes the wait.
      onError: (Object _) {},
    );
    return controller.stream;
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller?.close();
    _controller = null;
  }
}
