/// Controls how much native logging the plugin emits on supported platforms.
enum NativeLogLevel {
  /// Disables all native logs from the plugin.
  none('none'),

  /// Emits only error logs.
  error('error'),

  /// Emits warnings and errors.
  warning('warning'),

  /// Emits informational messages, warnings, and errors.
  info('info'),

  /// Emits debug, info, warning, and error logs.
  debug('debug'),

  /// Emits all available logs, including verbose output.
  verbose('verbose');

  const NativeLogLevel(this.methodValue);

  /// String value sent over the platform channel.
  final String methodValue;
}
