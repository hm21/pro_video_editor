import XCTest

@testable import pro_video_editor

// Compiled into *both* the iOS and the macOS RunnerTests target (referenced
// from each project as ../shared_tests/…): the overlap pre-render is shared
// Darwin code, mirrored by ClipTransitionGeometryTest.kt on Android.

/// Which overlap blends start after the render's end, so the pre-render can
/// leave them out: a 6.3 s export of 50 clips rendered all 49 blends.
final class ClipTransitionWindowTests: XCTestCase {
  private typealias Geometry = ClipTransitionGeometry

  private func clip(_ sourceMs: Int64, blendMs: Int64? = nil, speed: Float? = nil)
    -> Geometry.TimelineClip
  {
    Geometry.TimelineClip(
      sourceDurationUs: sourceMs * 1_000, speed: speed,
      blendDurationUs: blendMs.map { $0 * 1_000 })
  }

  func testOnlyTheBlendsInsideTheRenderAreKept() {
    // 50 clips of 4s with 500ms blends: blend 0 runs 3.5..4.0s, blend 1 starts
    // at 7.0s, after a 6.3s render end, and so does every later one.
    let clips = (0..<50).map { clip(4_000, blendMs: $0 < 49 ? 500 : nil) }

    let pastEnd = Geometry.blendsPastEnd(clips: clips, endUs: 6_300_000)

    XCTAssertFalse(pastEnd[0])
    XCTAssertEqual(pastEnd.indices.filter { pastEnd[$0] }, Array(1..<49))
  }

  func testKeepsABlendTheEndCutsThrough() {
    // Blend 0 starts at 3.5s; an end inside it still shows its first frames.
    let clips = [clip(4_000, blendMs: 500), clip(4_000)]

    XCTAssertEqual(Geometry.blendsPastEnd(clips: clips, endUs: 3_700_000), [false, false])
    XCTAssertEqual(Geometry.blendsPastEnd(clips: clips, endUs: 3_500_000), [true, false])
  }

  func testPlacesBlendsAfterTheHeadThePreviousOneTook() {
    // Blend 0 takes 500ms of clip 1's head, so blend 1 starts at 7.0s, not
    // 7.5s: a 7.2s end still shows it.
    let clips = [clip(4_000, blendMs: 500), clip(4_000, blendMs: 500), clip(4_000)]

    XCTAssertEqual(
      Geometry.blendsPastEnd(clips: clips, endUs: 7_200_000), [false, false, false])
  }

  func testLaysClipsOutInOutputTime() {
    // At 2x a 4s source plays for 2s, so blend 0 starts at 1.5s and blend 1
    // at 3.0s.
    let clips = [
      clip(4_000, blendMs: 500, speed: 2), clip(4_000, blendMs: 500, speed: 2),
      clip(4_000, speed: 2),
    ]

    XCTAssertEqual(
      Geometry.blendsPastEnd(clips: clips, endUs: 2_000_000), [false, true, false])
  }

  func testStartOffsetPullsEveryBlendEarlier() {
    // A loop wrap of up to 500ms moves the first clip's head to the end, so
    // blend 1 may start as early as 6.5s.
    let clips = [clip(4_000, blendMs: 500), clip(4_000, blendMs: 500), clip(4_000)]

    XCTAssertEqual(
      Geometry.blendsPastEnd(clips: clips, endUs: 6_800_000, startOffsetUs: -500_000),
      [false, false, false])
  }

  func testIsEmptyWithoutAnEnd() {
    let clips = [clip(4_000, blendMs: 500), clip(4_000)]

    XCTAssertEqual(Geometry.blendsPastEnd(clips: clips, endUs: nil), [false, false])
  }

  func testClipTimelineEndUndoesTheGlobalSpeed() {
    // 6.3s of output at 2x is 12.6s of the clips' own timeline.
    XCTAssertEqual(Geometry.clipTimelineEndUs(globalEndUs: 6_300_000, globalSpeed: 2), 12_600_000)
    XCTAssertEqual(
      Geometry.clipTimelineEndUs(globalEndUs: 6_300_000, globalSpeed: nil), 6_300_000)
    XCTAssertNil(Geometry.clipTimelineEndUs(globalEndUs: nil, globalSpeed: 2))
  }
}
