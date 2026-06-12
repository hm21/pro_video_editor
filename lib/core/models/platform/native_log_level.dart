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

  /// Parses a [NativeLogLevel] from its [methodValue] string.
  ///
  /// Accepts the canonical [methodValue]s as well as the common `warn` alias
  /// (mapped to [warning]). Unknown values fall back to [info] so that a log
  /// entry is never dropped just because the native side used an unexpected
  /// label.
  static NativeLogLevel fromMethodValue(String value) {
    switch (value.toLowerCase()) {
      case 'none':
        return NativeLogLevel.none;
      case 'error':
        return NativeLogLevel.error;
      case 'warn':
      case 'warning':
        return NativeLogLevel.warning;
      case 'info':
        return NativeLogLevel.info;
      case 'debug':
        return NativeLogLevel.debug;
      case 'verbose':
        return NativeLogLevel.verbose;
      default:
        return NativeLogLevel.info;
    }
  }
}
