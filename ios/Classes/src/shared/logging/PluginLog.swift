import Foundation

enum PluginLogLevel: Int {
  case verbose = 0
  case debug = 1
  case info = 2
  case warning = 3
  case error = 4
  case none = 5

  static var `default`: PluginLogLevel {
    #if DEBUG
      return .debug
    #else
      return .warning
    #endif
  }

  static func from(methodValue: String) throws -> PluginLogLevel {
    switch methodValue.lowercased() {
    case "verbose":
      return .verbose
    case "debug":
      return .debug
    case "info":
      return .info
    case "warning", "warn":
      return .warning
    case "error":
      return .error
    case "none":
      return .none
    default:
      throw PluginLogError.unsupportedLevel(methodValue)
    }
  }
}

enum PluginLogError: LocalizedError {
  case unsupportedLevel(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedLevel(let level):
      return "Unsupported native log level: \(level)"
    }
  }
}

enum PluginLog {
  private static var minimumLevel = PluginLogLevel.default

  static func setMinimumLevel(_ methodValue: String) throws {
    minimumLevel = try .from(methodValue: methodValue)
  }

  static func print(
    _ items: Any..., separator: String = " ", terminator: String = "\n"
  ) {
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    log(message, terminator: terminator)
  }

  private static func log(_ message: String, terminator: String) {
    let level = inferredLevel(for: message)
    guard shouldLog(level) else { return }
    Swift.print(message, terminator: terminator)
  }

  private static func shouldLog(_ level: PluginLogLevel) -> Bool {
    level.rawValue >= minimumLevel.rawValue && minimumLevel != .none
  }

  private static func inferredLevel(for message: String) -> PluginLogLevel {
    if message.contains("❌") || message.localizedCaseInsensitiveContains("error") ||
      message.localizedCaseInsensitiveContains("failed")
    {
      return .error
    }

    if message.contains("⚠️") || message.localizedCaseInsensitiveContains("warn") {
      return .warning
    }

    if message.contains("ℹ️") || message.localizedCaseInsensitiveContains("info") {
      return .info
    }

    return .debug
  }
}