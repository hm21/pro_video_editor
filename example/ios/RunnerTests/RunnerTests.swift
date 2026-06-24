import Flutter
import UIKit
import XCTest


@testable import pro_video_editor

// This demonstrates a simple unit test of the Swift portion of this plugin's implementation.
//
// See https://developer.apple.com/documentation/xctest for more information about using XCTest.

class RunnerTests: XCTestCase {

  func testGetPlatformVersion() {
    let plugin = ProVideoEditorPlugin()

    let call = FlutterMethodCall(methodName: "getPlatformVersion", arguments: [])

    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertEqual(result as! String, "iOS " + UIDevice.current.systemVersion)
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  // MARK: - Slide animation geometry

  // Frame 1000×500, a small layer (200×100) centered at (400, 200) in
  // Core Graphics (Y bottom-up) coordinates.
  private let slideFrame = CGRect(x: 0, y: 0, width: 1000, height: 500)
  private let slideOverlay = CGRect(x: 400, y: 200, width: 200, height: 100)

  func testSlideMovesLayerFullyOutAtInvPOne() {
    let left = slideOffset(
      direction: "left", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let right = slideOffset(
      direction: "right", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let top = slideOffset(
      direction: "top", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let bottom = slideOffset(
      direction: "bottom", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)

    // Edge-aware distance, not the old overlay-size-relative one.
    XCTAssertEqual(left.x, -600, accuracy: 1e-6)
    XCTAssertEqual(right.x, 600, accuracy: 1e-6)
    XCTAssertEqual(top.y, 300, accuracy: 1e-6)
    XCTAssertEqual(bottom.y, -300, accuracy: 1e-6)
  }

  func testSlideTrailingEdgeLandsOnFrameEdge() {
    let left = slideOffset(
      direction: "left", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let right = slideOffset(
      direction: "right", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let top = slideOffset(
      direction: "top", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let bottom = slideOffset(
      direction: "bottom", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)

    XCTAssertEqual(slideOverlay.maxX + left.x, slideFrame.minX, accuracy: 1e-6)
    XCTAssertEqual(slideOverlay.minX + right.x, slideFrame.maxX, accuracy: 1e-6)
    XCTAssertEqual(slideOverlay.minY + top.y, slideFrame.maxY, accuracy: 1e-6)
    XCTAssertEqual(slideOverlay.maxY + bottom.y, slideFrame.minY, accuracy: 1e-6)
  }

  func testSlideIsZeroAtRestAndLinearInInvP() {
    let rest = slideOffset(
      direction: "left", invP: 0, overlayExtent: slideOverlay, frameExtent: slideFrame)
    XCTAssertEqual(rest.x, 0, accuracy: 1e-6)
    XCTAssertEqual(rest.y, 0, accuracy: 1e-6)

    let full = slideOffset(
      direction: "left", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    let half = slideOffset(
      direction: "left", invP: 0.5, overlayExtent: slideOverlay, frameExtent: slideFrame)
    XCTAssertEqual(half.x, full.x / 2, accuracy: 1e-6)
  }

  func testSlideUnknownDirectionProducesNoOffset() {
    let off = slideOffset(
      direction: "diagonal", invP: 1, overlayExtent: slideOverlay, frameExtent: slideFrame)
    XCTAssertEqual(off.x, 0, accuracy: 1e-6)
    XCTAssertEqual(off.y, 0, accuracy: 1e-6)
  }

}
