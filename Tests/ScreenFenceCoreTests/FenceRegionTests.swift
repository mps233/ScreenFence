import CoreGraphics
import XCTest
@testable import ScreenFenceCore

final class FenceRegionTests: XCTestCase {
    private let main = FenceRegion(bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))!

    func testRightEdgeKeepsVerticalMovement() {
        XCTAssertEqual(main.constrain(CGPoint(x: 1960, y: 200)), CGPoint(x: 1919, y: 200))
        XCTAssertEqual(main.constrain(CGPoint(x: 2000, y: 750)), CGPoint(x: 1919, y: 750))
    }

    func testBottomEdgeKeepsHorizontalMovement() {
        XCTAssertEqual(main.constrain(CGPoint(x: 200, y: 1130)), CGPoint(x: 200, y: 1079))
        XCTAssertEqual(main.constrain(CGPoint(x: 1700, y: 1500)), CGPoint(x: 1700, y: 1079))
    }

    func testEveryEdgeAndCornerStaysStrictlyInsideDisplay() {
        for x in stride(from: -800.0, through: 2700.0, by: 31.25) {
            for y in stride(from: -800.0, through: 2000.0, by: 29.75) {
                let corrected = main.constrain(CGPoint(x: x, y: y))
                XCTAssertTrue(main.contains(corrected))
                XCTAssertTrue(main.bounds.contains(corrected))
            }
        }
    }

    func testContinuedOutwardMotionCannotAccumulateInRegionState() {
        for distance in [1.0, 100, 100_000] {
            XCTAssertEqual(main.constrain(CGPoint(x: 1920 + distance, y: 300)).x, 1919)
        }
        XCTAssertEqual(main.constrain(CGPoint(x: 1918, y: 300)).x, 1918)
        XCTAssertEqual(main.constrain(CGPoint(x: 1918, y: 1078)), CGPoint(x: 1918, y: 1078))
    }

    func testNegativeOriginsAndFractionalCoordinates() {
        let left = FenceRegion(bounds: CGRect(x: -2560, y: -400, width: 2560, height: 1440))!
        XCTAssertEqual(left.constrain(CGPoint(x: 0, y: -23.5)), CGPoint(x: -1, y: -23.5))
        XCTAssertEqual(left.constrain(CGPoint(x: -1500.25, y: 1300)), CGPoint(x: -1500.25, y: 1039))
        XCTAssertEqual(left.constrain(CGPoint(x: -3000, y: -800)), CGPoint(x: -2560, y: -400))
    }

    func testInvalidDisplayGeometryIsRejected() {
        XCTAssertNil(FenceRegion(bounds: .zero))
        XCTAssertNil(FenceRegion(bounds: CGRect(x: 0, y: 0, width: -100, height: 100)))
        XCTAssertNil(FenceRegion(bounds: CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)))
        XCTAssertNil(FenceRegion(bounds: main.bounds, edgeInset: 0))
    }

    func testFilterKeepsDragTypeDeltasButtonsAndModifiers() throws {
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .rightMouseDragged,
            mouseCursorPosition: CGPoint(x: 1990, y: 430), mouseButton: .right
        ))
        event.setDoubleValueField(.mouseEventDeltaX, value: 70)
        event.setDoubleValueField(.mouseEventDeltaY, value: -12.5)
        event.setIntegerValueField(.mouseEventButtonNumber, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: 123456)
        event.flags = [.maskShift, .maskAlternate]
        let deltaYBeforeFiltering = event.getDoubleValueField(.mouseEventDeltaY)
        XCTAssertTrue(FenceEventFilter.constrain(event, to: main))
        XCTAssertEqual(event.location, CGPoint(x: 1919, y: 430))
        XCTAssertEqual(event.type, .rightMouseDragged)
        XCTAssertEqual(event.getDoubleValueField(.mouseEventDeltaX), 70)
        XCTAssertEqual(event.getDoubleValueField(.mouseEventDeltaY), deltaYBeforeFiltering)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), 1)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), 123456)
        XCTAssertEqual(event.flags, [.maskShift, .maskAlternate])
    }

    func testUnchangedEventDoesNotGetRewritten() throws {
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 123.25, y: 333.75), mouseButton: .left
        ))
        XCTAssertFalse(FenceEventFilter.constrain(event, to: main))
        XCTAssertEqual(event.location, CGPoint(x: 123.25, y: 333.75))
    }
}
