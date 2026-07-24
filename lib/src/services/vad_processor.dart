abstract interface class VadProcessor {
  Future<void> start();
  Future<void> stop();
  Stream<bool> get speechActivity;
}

/// First-demo implementation. A model-backed VAD can replace this without
/// changing Hub registration or LiveKit session code.
final class NoOpVadProcessor implements VadProcessor {
  const NoOpVadProcessor();

  @override
  Stream<bool> get speechActivity => const Stream<bool>.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}
