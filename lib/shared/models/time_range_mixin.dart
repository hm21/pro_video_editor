/// A mixin that provides optional start and end time fields for timeline-based
/// elements.
///
/// Classes that mix in [TimeRangeMixin] can be constrained to be active only
/// during a specific time range of the video.
///
/// - If [startTime] is `null`, the element starts from the beginning.
/// - If [endTime] is `null`, the element lasts until the end.
mixin TimeRangeMixin {
  /// The start time for this element, relative to the start of the video.
  ///
  /// If `null`, the element is active from the beginning of the video.
  Duration? get startTime;

  /// The end time for this element, relative to the start of the video.
  ///
  /// If `null`, the element is active until the end of the video.
  Duration? get endTime;
}
