#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// FlutterStreamHandler conformance for ProVideoEditorPlugin.
///
/// Manages the event channel for progress updates.
/// Progress events are streamed to Flutter with task ID and progress value (0.0 to 1.0).
extension ProVideoEditorPlugin: FlutterStreamHandler {
  #if os(iOS)
  @objc public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  @objc public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }
  #elseif os(macOS)
  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }
  #endif
}

/// FlutterStreamHandler for waveform streaming events.
///
/// Manages the event channel for streaming waveform chunks.
/// Waveform chunks are streamed to Flutter as they are generated.
class WaveformStreamHandler: NSObject, FlutterStreamHandler {
  private weak var plugin: ProVideoEditorPlugin?

  init(plugin: ProVideoEditorPlugin) {
    self.plugin = plugin
    super.init()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    plugin?.waveformStreamSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    plugin?.waveformStreamSink = nil
    return nil
  }
}