import XCTest
@testable import EgressMapper

/// `EdgeAvailability` is the only place that decides whether a segment is
/// usable, so these are the load-bearing cases for every routing decision.
final class EdgeAvailabilityTests: XCTestCase {

    private func edge(hazard: RouteHazard? = nil, blocked: Bool = false, restriction: Int? = nil) -> RouteEdge {
        RouteEdge(
            fromNodeID: UUID(), toNodeID: UUID(), distanceMeters: 10,
            isBlocked: blocked, hazard: hazard, restrictionSeverity: restriction
        )
    }

    func testPlainEdgeIsAvailable() {
        XCTAssertEqual(edge().availability, .available)
        XCTAssertEqual(edge().hazardPenalty, 1)
    }

    func testExplicitBlockIsUnavailableRegardlessOfHazard() {
        let e = edge(hazard: RouteHazard(type: .crowding), blocked: true)
        XCTAssertEqual(e.availability, .unavailable)
        XCTAssertTrue(e.isImpassable)
    }

    func testHazardsThatCloseASegmentAreUnavailableNotExpensive() {
        for type in [RouteHazardType.fire, .lockedDoor, .unavailableStairwell, .unavailableElevator, .blockedHallway] {
            let e = edge(hazard: RouteHazard(type: type, severity: 1))
            XCTAssertEqual(e.availability, .unavailable, "\(type) must be removed, not priced")
        }
    }

    func testPassableHazardsScaleWithSeverity() {
        let light = edge(hazard: RouteHazard(type: .smoke, severity: 1))
        let heavy = edge(hazard: RouteHazard(type: .smoke, severity: 5))
        XCTAssertFalse(light.isImpassable)
        XCTAssertGreaterThan(heavy.hazardPenalty, light.hazardPenalty)
    }

    func testCrowdingSlowsTravelButNeverClosesACorridor() {
        let e = edge(hazard: RouteHazard(type: .crowding, severity: 5))
        XCTAssertFalse(e.isImpassable)
        XCTAssertGreaterThan(e.hazardPenalty, 1)
    }

    /// A published `restricted` status is the administrator saying "usable, but
    /// avoid". It must not be silently promoted to a hard block by the hazard
    /// type they happened to pick.
    func testRestrictedStaysPassableEvenForAClosingHazardType() {
        let e = edge(hazard: RouteHazard(type: .fire, severity: 5), restriction: 5)
        XCTAssertFalse(e.isImpassable)
        XCTAssertGreaterThan(e.hazardPenalty, edge(hazard: RouteHazard(type: .smoke, severity: 5), restriction: 5).hazardPenalty)
    }

    /// Maps saved before `restrictionSeverity` existed must still decode.
    func testEdgeDecodesWithoutRestrictionField() throws {
        let json = """
        {"id":"\(UUID().uuidString)","fromNodeID":"\(UUID().uuidString)","toNodeID":"\(UUID().uuidString)",
         "distanceMeters":12.5,"isBidirectional":true,"isBlocked":false,
         "accessibility":{"containsStairs":false,"requiresElevator":false,"wheelchairAccessible":true}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RouteEdge.self, from: json)
        XCTAssertNil(decoded.restrictionSeverity)
        XCTAssertEqual(decoded.availability, .available)
    }

    /// The router removes unavailable edges rather than pricing them, so no
    /// finite cost can ever make one attractive.
    func testRouterRefusesUnavailableEdges() {
        let e = edge(hazard: RouteHazard(type: .fire))
        XCTAssertFalse(ShortestPathService.isTraversable(e, profile: .standard))
        XCTAssertTrue(ShortestPathService.isTraversable(edge(hazard: RouteHazard(type: .crowding)), profile: .standard))
    }
}
