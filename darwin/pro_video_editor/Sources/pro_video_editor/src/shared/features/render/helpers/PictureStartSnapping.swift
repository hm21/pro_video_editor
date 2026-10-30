import AVFoundation
import Foundation

/// Moves a trim onto the picture it names when it misses that picture's start
/// by at most a microsecond.
///
/// Trims arrive in whole microseconds, but most pictures start between two:
/// picture 86 of a 30 fps clip starts at 2866666.67 µs. A frame time read back
/// in microseconds is rounded (iOS, macOS) or truncated (Android), so a cut
/// taken from one misses its picture by a fraction of a microsecond. An end
/// that far past a picture's start keeps a sliver of that picture, and a start
/// that far before it keeps a sliver of the picture before; either sliver
/// renders as a whole frame.
internal enum PictureStartSnapping {

  /// How far a trim may miss a picture's start and still mean it: the error of
  /// a time rounded or truncated to whole microseconds.
  static let tolerance = CMTime(value: 1, timescale: 1_000_000)

  /// `time` on `track`'s timeline, moved onto the picture starting within
  /// `tolerance` of it, or unchanged when none does.
  static func snapped(_ time: CMTime, on track: AVAssetTrack) async -> CMTime {
    let mediaTimeScale: CMTimeScale
    let segments: [AVAssetTrackSegment]
    if #available(iOS 15.0, macOS 13.0, *) {
      mediaTimeScale = (try? await track.load(.naturalTimeScale)) ?? track.naturalTimeScale
      segments = (try? await track.load(.segments)) ?? track.segments
    } else {
      mediaTimeScale = track.naturalTimeScale
      segments = track.segments
    }
    return snapped(
      time, mediaTimeScale: mediaTimeScale,
      edits: segments.filter { !$0.isEmpty }.map(\.timeMapping))
  }

  /// `time` moved onto a picture start within `tolerance` of it, for a track
  /// whose media runs on `mediaTimeScale` and plays through `edits`.
  ///
  /// Every picture starts on a tick of the media timescale, so the nearest
  /// tick is the only one that can be close enough. The edit at `time` maps it
  /// into media time, which an edit list can shift against the track; an edit
  /// that plays its media at another rate is left alone.
  static func snapped(
    _ time: CMTime, mediaTimeScale: CMTimeScale, edits: [CMTimeMapping]
  ) -> CMTime {
    guard time.isNumeric, mediaTimeScale > 0,
      let edit = edits.first(where: {
        CMTimeSubtract($0.target.start, tolerance) <= time
          && time <= CMTimeAdd(CMTimeRangeGetEnd($0.target), tolerance)
      }),
      edit.source.duration == edit.target.duration
    else { return time }

    let media = CMTimeAdd(edit.source.start, CMTimeSubtract(time, edit.target.start))
    let tick = CMTimeConvertScale(
      media, timescale: mediaTimeScale, method: .roundHalfAwayFromZero)
    guard tick.isNumeric, CMTimeAbsoluteValue(CMTimeSubtract(tick, media)) <= tolerance
    else { return time }
    return edit.source.start == edit.target.start
      ? tick : CMTimeAdd(edit.target.start, CMTimeSubtract(tick, edit.source.start))
  }
}
