import XCTest
import CoreGraphics
@testable import EgressMapper

final class FloorPlanAlignmentTests: XCTestCase {

    private func pair(_ mx: Double, _ my: Double, _ px: Double, _ py: Double)
    -> FloorPlanAlignmentService.Correspondence {
        .init(mapPoint: MapPoint(x: mx, y: my), planPoint: CGPoint(x: px, y: py))
    }

    func testPureScale() throws {
        // 1 map metre -> 10 plan pixels, no rotation, no offset.
        let a = try FloorPlanAlignmentService.solve([
            pair(0, 0, 0, 0),
            pair(10, 0, 100, 0),
        ])
        XCTAssertEqual(a.scale, 10, accuracy: 1e-6)
        XCTAssertEqual(a.rotation, 0, accuracy: 1e-6)
        XCTAssertEqual(a.rmsError, 0, accuracy: 1e-6)
    }

    func testTranslation() throws {
        let a = try FloorPlanAlignmentService.solve([
            pair(0, 0, 50, 20),
            pair(1, 0, 51, 20),
        ])
        XCTAssertEqual(a.scale, 1, accuracy: 1e-6)
        XCTAssertEqual(a.translationX, 50, accuracy: 1e-6)
        XCTAssertEqual(a.translationY, 20, accuracy: 1e-6)
    }

    func testNinetyDegreeRotation() throws {
        // Map +X maps to plan +Y => +90°.
        let a = try FloorPlanAlignmentService.solve([
            pair(0, 0, 0, 0),
            pair(1, 0, 0, 1),
        ])
        XCTAssertEqual(a.rotation, .pi / 2, accuracy: 1e-6)
        XCTAssertEqual(a.scale, 1, accuracy: 1e-6)

        let projected = a.apply(MapPoint(x: 1, y: 0))
        XCTAssertEqual(Double(projected.x), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(projected.y), 1, accuracy: 1e-6)
    }

    func testRoundTripThroughInverse() throws {
        let a = try FloorPlanAlignmentService.solve([
            pair(0, 0, 120, 80),
            pair(10, 5, 300, 260),
            pair(0, 5, 60, 240),
        ])
        let original = MapPoint(x: 4.2, y: 2.6)
        let back = a.invert(a.apply(original))
        XCTAssertEqual(back.x, original.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, original.y, accuracy: 1e-6)
    }

    func testThreePointFitReportsResidualError() throws {
        // Third point deliberately inconsistent — fit must not silently claim
        // to be perfect.
        let a = try FloorPlanAlignmentService.solve([
            pair(0, 0, 0, 0),
            pair(10, 0, 100, 0),
            pair(5, 0, 50, 40),
        ])
        XCTAssertGreaterThan(a.rmsError, 1)
    }

    func testTooFewPointsThrows() {
        XCTAssertThrowsError(try FloorPlanAlignmentService.solve([pair(0, 0, 0, 0)])) { error in
            guard case FloorPlanAlignmentError.notEnoughPoints = error else {
                return XCTFail("Expected .notEnoughPoints, got \(error)")
            }
        }
    }

    func testCoincidentPointsThrow() {
        XCTAssertThrowsError(try FloorPlanAlignmentService.solve([
            pair(3, 3, 10, 10),
            pair(3, 3, 10, 10),
        ])) { error in
            guard case FloorPlanAlignmentError.degeneratePoints = error else {
                return XCTFail("Expected .degeneratePoints, got \(error)")
            }
        }
    }

    func testAlignmentCodableRoundTrip() throws {
        let a = FloorPlanAlignment(scale: 12.5, rotation: 0.7, translationX: 30, translationY: -14, rmsError: 2.1)
        let decoded = try JSONDecoder().decode(
            FloorPlanAlignment.self, from: JSONEncoder().encode(a)
        )
        XCTAssertEqual(decoded, a)
    }

    func testFittedRectCentersAndPreservesAspect() {
        let rect = FloorPlanAlignmentView.fittedRect(
            imageSize: CGSize(width: 200, height: 100),
            in: CGSize(width: 400, height: 400)
        )
        XCTAssertEqual(rect.width, 400, accuracy: 1e-6)
        XCTAssertEqual(rect.height, 200, accuracy: 1e-6)
        XCTAssertEqual(rect.minY, 100, accuracy: 1e-6)
        XCTAssertEqual(rect.minX, 0, accuracy: 1e-6)
    }

    func testFittedRectHandlesZeroSize() {
        let rect = FloorPlanAlignmentView.fittedRect(imageSize: .zero, in: CGSize(width: 10, height: 10))
        XCTAssertEqual(rect, .zero)
    }
}

final class RoomSignRecognizerTests: XCTestCase {

    func testRecognizesRoomVariants() {
        for input in ["Room 214", "ROOM 214", "Rm 214", "RM. 214", "214"] {
            let sign = RoomSignRecognizer.classify(input)
            XCTAssertEqual(sign?.type, .room, "failed on \(input)")
            XCTAssertEqual(sign?.suggestedName, "Room 214", "failed on \(input)")
        }
    }

    func testRecognizesExitStairElevator() {
        XCTAssertEqual(RoomSignRecognizer.classify("EXIT")?.type, .exit)
        XCTAssertEqual(RoomSignRecognizer.classify("Exit A")?.type, .exit)
        XCTAssertEqual(RoomSignRecognizer.classify("Stair A")?.type, .stairwell)
        XCTAssertEqual(RoomSignRecognizer.classify("STAIRWELL B")?.type, .stairwell)
        XCTAssertEqual(RoomSignRecognizer.classify("Elevator")?.type, .elevator)
    }

    func testRoomNumberWithLetterSuffix() {
        XCTAssertEqual(RoomSignRecognizer.classify("Room 214B")?.suggestedName, "Room 214B")
    }

    func testRejectsNoise() {
        for input in ["", "A", "Welcome to the science wing", "!!!", "7"] {
            XCTAssertNil(RoomSignRecognizer.classify(input), "should reject \(input)")
        }
    }

    func testRejectsYearsThatLookLikeRoomNumbers() {
        // A "2024" on a plaque is not room 2024.
        XCTAssertNil(RoomSignRecognizer.classify("2024"))
        XCTAssertNil(RoomSignRecognizer.classify("1999"))
        // But a genuine 4-digit room outside that band still works.
        XCTAssertEqual(RoomSignRecognizer.classify("3410")?.suggestedName, "Room 3410")
    }
}

final class MarkerHeightTests: XCTestCase {

    func testEyeLevelKeepsCapturedHeight() {
        let y = ARRouteRenderer.placementY(capturedY: 1.4, groundY: -0.2, mode: .eyeLevel, offset: 0)
        XCTAssertEqual(y, 1.4, accuracy: 1e-6)
    }

    func testFloorUsesDetectedPlaneNotCaptureHeight() {
        let y = ARRouteRenderer.placementY(capturedY: 1.4, groundY: -0.25, mode: .floor, offset: 0)
        XCTAssertEqual(y, -0.25, accuracy: 1e-6, "Detected floor must win over the assumed height")
    }

    func testFloorFallsBackToAssumedHeightWhenNoPlane() {
        let y = ARRouteRenderer.placementY(capturedY: 1.4, groundY: nil, mode: .floor, offset: 0)
        XCTAssertEqual(y, 1.4 - ARRouteRenderer.assumedCaptureHeight, accuracy: 1e-6)
    }

    func testOffsetAppliesInBothModes() {
        XCTAssertEqual(
            ARRouteRenderer.placementY(capturedY: 1.4, groundY: -0.2, mode: .floor, offset: 0.5),
            0.3, accuracy: 1e-6
        )
        XCTAssertEqual(
            ARRouteRenderer.placementY(capturedY: 1.4, groundY: -0.2, mode: .eyeLevel, offset: -0.4),
            1.0, accuracy: 1e-6
        )
    }

    func testFloorModeIsNeverAboveEyeLevelForSaneInputs() {
        let floor = ARRouteRenderer.placementY(capturedY: 1.5, groundY: 0, mode: .floor, offset: 0)
        let eye = ARRouteRenderer.placementY(capturedY: 1.5, groundY: 0, mode: .eyeLevel, offset: 0)
        XCTAssertLessThan(floor, eye)
    }
}
