import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// A job started over the method channel that answers its call exactly once.
///
/// `RenderTask` and `AudioExtractTask` both hold the call's `FlutterResult`
/// and consume it on the first answer; this is the part of them the plugin
/// needs to settle a job the same way whichever map it lives in.
protocol ChannelTask: AnyObject {
  var isCanceled: Bool { get }
  func sendSuccess(_ payload: Any?)
  func sendError(_ error: FlutterError)
}

extension RenderTask: ChannelTask {}
extension AudioExtractTask: ChannelTask {}
