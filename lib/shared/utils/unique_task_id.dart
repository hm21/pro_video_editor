/// The last id [uniqueTaskId] handed out.
int _lastTaskId = 0;

/// An id for a native task that no earlier call in this isolate returned.
///
/// The microseconds since the epoch, raised past the last id when the clock
/// has not moved on. A bare timestamp is not enough: configs built in one go,
/// like the waveforms of several voice-overs inside one `Future.wait`, read
/// the same clock value, and the platforms reject a second task that runs
/// under an id still in use with `TASK_ALREADY_RUNNING`.
String uniqueTaskId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  _lastTaskId = now > _lastTaskId ? now : _lastTaskId + 1;
  return '$_lastTaskId';
}
