import 'dart:async';

/// Observes an unfinished Admission without issuing another user command.
/// Both setup and approval screens follow the same lifetime: one read at a
/// time, paused in the background, stopped at a terminal projection.
class AdmissionObservation {
  AdmissionObservation(this.read, {this.interval = const Duration(seconds: 3)});

  final Future<void> Function() read;
  final Duration interval;
  Timer? _timer;
  bool _waiting = false;
  bool _paused = false;
  bool _reading = false;
  bool _disposed = false;

  void setWaiting(bool waiting) {
    _waiting = waiting;
    _timer?.cancel();
    _schedule();
  }

  void _schedule() {
    if (_disposed || _paused || !_waiting || _reading) return;
    _timer = Timer(interval, () async {
      _reading = true;
      try {
        await read();
      } finally {
        _reading = false;
        _schedule();
      }
    });
  }

  void pause() {
    _paused = true;
    _timer?.cancel();
  }

  void resume() {
    _paused = false;
    _timer?.cancel();
    _schedule();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
