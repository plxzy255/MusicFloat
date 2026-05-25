import XCTest
@testable import MusicFloat

final class FloatingPanelPlacementTests: XCTestCase {
    func testDefaultFrameCentersNearTopAndStaysInsideVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let frame = FloatingPanelController.testPlacementDefaultFrame(
            size: CGSize(width: 400, height: 120),
            visibleFrame: visibleFrame,
            topInset: 80
        )

        XCTAssertEqual(frame.origin.x, 300, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 600, accuracy: 0.001)
        XCTAssertEqual(frame.width, 400, accuracy: 0.001)
        XCTAssertEqual(frame.height, 120, accuracy: 0.001)
    }

    func testClampedFrameCannotLeaveVisibleFrame() {
        let visibleFrame = CGRect(x: 100, y: 200, width: 500, height: 300)

        let frame = FloatingPanelController.testPlacementClamped(
            CGRect(x: -200, y: 700, width: 640, height: 400),
            to: visibleFrame
        )

        XCTAssertEqual(frame.origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 200, accuracy: 0.001)
        XCTAssertEqual(frame.width, 500, accuracy: 0.001)
        XCTAssertEqual(frame.height, 300, accuracy: 0.001)
    }

    func testResizePreservesTopCenter() {
        let current = CGRect(x: 200, y: 300, width: 400, height: 120)

        let frame = FloatingPanelController.testPlacementFramePreservingTopCenter(
            currentFrame: current,
            size: CGSize(width: 600, height: 160)
        )

        XCTAssertEqual(frame.midX, current.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, current.maxY, accuracy: 0.001)
        XCTAssertEqual(frame.width, 600, accuracy: 0.001)
        XCTAssertEqual(frame.height, 160, accuracy: 0.001)
    }
}
