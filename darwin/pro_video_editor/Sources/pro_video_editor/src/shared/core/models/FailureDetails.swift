import Foundation

/// The `details` a failed job attaches to its `FlutterError`.
///
/// A `FlutterError`'s message is the platform's own description of what went
/// wrong, which is written for a person, in that person's language:
/// `AVErrorDiskFull` reads "Disk Full" on an English device and "Das Volume
/// ist voll." on a German one. Nothing an app can branch on survives that, so
/// the details carry what does — the error's domain and code, plus the chain
/// underneath it — in the same shape Android's `FailureDetails` produces from
/// a `Throwable`.
///
/// Keys:
/// - `domain`: `NSError.domain` — `AVFoundationErrorDomain`,
///   `NSPOSIXErrorDomain`, `ExportWatchdog`, or a Swift error's type name.
/// - `code`: `NSError.code` within that domain.
/// - `cause`: every `NSUnderlyingErrorKey` below it, outermost first, as
///   `<domain> <code>: <description>`. Absent when there is none.
enum FailureDetails {
  /// Nested underlying errors deeper than this are cut off; a chain that long
  /// is a cycle or a bug, and the top levels already say what happened.
  private static let maxCauseDepth = 8

  static func of(_ error: Error) -> [String: Any] {
    let nsError = error as NSError
    var details: [String: Any] = [
      "domain": nsError.domain,
      "code": nsError.code,
    ]
    let cause = underlyingChain(of: nsError)
      .map { "\($0.domain) \($0.code): \($0.localizedDescription)" }
      .joined(separator: " <- ")
    if !cause.isEmpty {
      details["cause"] = cause
    }
    return details
  }

  private static func underlyingChain(of error: NSError) -> [NSError] {
    var chain: [NSError] = []
    var current = error.userInfo[NSUnderlyingErrorKey] as? NSError
    while let next = current, chain.count < maxCauseDepth {
      chain.append(next)
      current = next.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return chain
  }
}
