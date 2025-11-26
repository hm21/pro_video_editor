/// Exceptions thrown during render operations.
class RenderCanceledException implements Exception {
  /// Creates a [RenderCanceledException].
  const RenderCanceledException();

  @override
  String toString() => 'RenderCanceledException';
}
