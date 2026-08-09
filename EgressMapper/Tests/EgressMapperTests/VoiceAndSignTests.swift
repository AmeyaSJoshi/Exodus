import XCTest
import simd
@testable import EgressMapper

private func node(_ name: String, _ type: RouteNodeType = .room) -> RouteNode {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(0, 1.4, 0, 1)
    return RouteNode(name: name, type: type, position: CodableTransform(m), zoneID: UUID())
}

final class VoiceCommandParserTests: XCTestCase {

    func testSupportedHazardPhrases() {
        XCTAssertEqual(
            VoiceCommandParser.parse("The hallway ahead is blocked"),
            .reportHazard(type: .blockedHallway, targetHint: "ahead")
        )
        XCTAssertEqual(
            VoiceCommandParser.parse("The door is locked"),
            .reportHazard(type: .lockedDoor, targetHint: nil)
        )
        XCTAssertEqual(
            VoiceCommandParser.parse("There is smoke ahead"),
            .reportHazard(type: .smoke, targetHint: "ahead")
        )
        XCTAssertEqual(
            VoiceCommandParser.parse("The elevator is not working"),
            .reportHazard(type: .unavailableElevator, targetHint: nil)
        )
        XCTAssertEqual(
            VoiceCommandParser.parse("The stairs are blocked"),
            .reportHazard(type: .unavailableStairwell, targetHint: nil)
        )
    }

    func testFireOutranksOtherKeywords() {
        XCTAssertEqual(
            VoiceCommandParser.parse("There is a fire in the blocked hallway"),
            .reportHazard(type: .fire, targetHint: nil)
        )
    }

    func testAccessibilityPhrasesUpdateTheProfileNotTheGraph() {
        XCTAssertEqual(
            VoiceCommandParser.parse("I can't use stairs"),
            .updateAccessibility(.avoidStairs)
        )
        XCTAssertEqual(
            VoiceCommandParser.parse("I need a wheelchair accessible route"),
            .updateAccessibility(.requireWheelchairAccessible)
        )
    }

    /// The critical ambiguity: a statement about the user must never be read
    /// as a hazard report that blocks the stairwell for everyone.
    func testCannotUseStairsIsNotAStairwellHazard() {
        let command = VoiceCommandParser.parse("I can't use the stairs")
        XCTAssertEqual(command, .updateAccessibility(.avoidStairs))
        if case .reportHazard = command { XCTFail("Must not block the stairwell") }
    }

    func testAlternativeExitRequest() {
        XCTAssertEqual(VoiceCommandParser.parse("Take me to another exit"), .requestAlternativeExit)
        XCTAssertEqual(VoiceCommandParser.parse("I want a different exit"), .requestAlternativeExit)
    }

    func testAmbiguousAndEmptyInputReturnsUnknown() {
        for input in ["", "hi", "what time is it", "the weather is nice today"] {
            guard case .unknown = VoiceCommandParser.parse(input) else {
                return XCTFail("Expected .unknown for “\(input)”")
            }
        }
    }

    func testPartialTranscriptDoesNotSilentlyBlockAnEdge() {
        // A half-heard phrase must not resolve to a hazard.
        guard case .unknown = VoiceCommandParser.parse("the hall") else {
            return XCTFail("A fragment must not block a segment")
        }
    }

    func testHazardCommandsRequireConfirmation() {
        XCTAssertTrue(VoiceCommandParser.parse("smoke ahead").requiresConfirmation)
        XCTAssertFalse(VoiceCommandParser.parse("I use a wheelchair").requiresConfirmation)
        XCTAssertFalse(VoiceCommandParser.parse("take me to another exit").requiresConfirmation)
    }

    func testProfileChangesApplyCorrectly() {
        let wheelchair = NavigationProfileChange.requireWheelchairAccessible.apply(to: .standard)
        XCTAssertTrue(wheelchair.requireWheelchairAccessible)
        XCTAssertTrue(wheelchair.avoidStairs, "Wheelchair implies avoiding stairs")

        let cleared = NavigationProfileChange.clearConstraints.apply(to: .wheelchair)
        XCTAssertFalse(cleared.hasAccessibilityConstraints)

        let noElevator = NavigationProfileChange.avoidElevators.apply(to: .standard)
        XCTAssertTrue(noElevator.avoidElevators)
        XCTAssertFalse(noElevator.avoidStairs)
    }

    func testCaseAndPunctuationAreIgnored() {
        XCTAssertEqual(
            VoiceCommandParser.parse("  THE HALLWAY AHEAD IS BLOCKED!  "),
            .reportHazard(type: .blockedHallway, targetHint: "ahead")
        )
    }
}

final class SignMatcherTests: XCTestCase {

    private let nodes = [
        node("Room 214"),
        node("Room 216"),
        node("Stair A", .stairwell),
        node("Central Intersection", .intersection),
        node("West Exit", .exit),
    ]

    func testExactRoomNumberMatchesRegardlessOfPrefix() {
        for text in ["214", "Room 214", "Rm 214", "RM. 214"] {
            let matches = SignMatcher.matches(text: text, nodes: nodes)
            XCTAssertEqual(matches.first?.node.name, "Room 214", "failed for \(text)")
            XCTAssertGreaterThanOrEqual(matches.first?.score ?? 0, 0.9)
        }
    }

    func testDoesNotConfuseNeighbouringRoomNumbers() {
        let matches = SignMatcher.matches(text: "Room 214", nodes: nodes)
        XCTAssertEqual(matches.first?.node.name, "Room 214")
        XCTAssertNotEqual(matches.first?.node.name, "Room 216")
    }

    func testStairSignMatchesStairwellNode() {
        let matches = SignMatcher.matches(text: "STAIR A", nodes: nodes)
        XCTAssertEqual(matches.first?.node.name, "Stair A")
    }

    func testMultiWordLandmarkMatchesOnTokenOverlap() {
        let matches = SignMatcher.matches(text: "Central Intersection", nodes: nodes)
        XCTAssertEqual(matches.first?.node.name, "Central Intersection")
    }

    func testUnrelatedTextProducesNoMatches() {
        XCTAssertTrue(SignMatcher.matches(text: "Fire Extinguisher", nodes: nodes).isEmpty)
        XCTAssertTrue(SignMatcher.matches(text: "Welcome", nodes: nodes).isEmpty)
    }

    func testUnknownRoomNumberIsNotForcedOntoTheNearestLabel() {
        XCTAssertTrue(
            SignMatcher.matches(text: "Room 999", nodes: nodes).isEmpty,
            "A room that is not on the map must not match anything"
        )
    }

    func testResultsAreRankedAndCapped() {
        let many = (1...10).map { node("Room 21\($0 % 10)") }
        let matches = SignMatcher.matches(text: "Room 214", nodes: many, limit: 3)
        XCTAssertLessThanOrEqual(matches.count, 3)
        if matches.count > 1 {
            XCTAssertGreaterThanOrEqual(matches[0].score, matches[1].score)
        }
    }

    func testTemporaryNodesAreNeverMatchable() {
        let withTemp = nodes + [node("Your Location", .temporaryStart)]
        let matches = SignMatcher.matches(text: "Your Location", nodes: withTemp)
        XCTAssertFalse(matches.contains { $0.node.type == .temporaryStart })
    }

    func testNormalizationStripsLabelNoise() {
        XCTAssertEqual(SignMatcher.normalize("Rm. 214"), "214")
        XCTAssertEqual(SignMatcher.normalize("ROOM  214"), "214")
        XCTAssertEqual(SignMatcher.numericToken("Room 214B"), "214B")
        XCTAssertNil(SignMatcher.numericToken("Exit"))
    }

    /// A matched sign must be usable as a start position for routing.
    func testMatchedSignProducesAUsableRoutePosition() throws {
        let match = try XCTUnwrap(SignMatcher.matches(text: "Room 214", nodes: nodes).first)
        let position = RoutePosition(nodeID: match.node.id, worldPosition: match.node.worldPosition)
        XCTAssertEqual(position.nodeID, match.node.id)
        XCTAssertTrue(position.isAtNode)
    }
}
