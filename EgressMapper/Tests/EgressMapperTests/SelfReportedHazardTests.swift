import XCTest
import simd
@testable import EgressMapper

/// Reporting a blockage by voice on a purely local map produced
/// "blocked by an administrator" — on a map that has no administrator, from a
/// report the user made themselves — with no way to undo it. The route stayed
/// dead for the rest of the session.
final class SelfReportedHazardTests: XCTestCase {

    private var root: URL!
    private var store: ZoneFileStore!
    private var zone: MappingZone!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("egress-hazard-\(UUID().uuidString)")
        store = ZoneFileStore(root: root)
        zone = MappingZone(campus: "Home", building: "House", floor: "1", zoneName: "Downstairs")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func at(_ x: Float) -> CodableTransform {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, 0, 0, 1)
        return CodableTransform(m)
    }

    /// One room, one hallway, one exit — the shape of a house map.
    private func makeGraph() -> (BuildingGraph, room: UUID, exitEdge: UUID) {
        let room = RouteNode(name: "Ameya Bedroom", type: .room, position: at(0), zoneID: zone.id)
        let hall = RouteNode(name: "Hallway", type: .hallwayPoint, position: at(5), zoneID: zone.id)
        let exit = RouteNode(name: "Game Room Exit", type: .exit, position: at(10), zoneID: zone.id)
        let toHall = RouteEdge(fromNodeID: room.id, toNodeID: hall.id, distanceMeters: 5)
        let toExit = RouteEdge(fromNodeID: hall.id, toNodeID: exit.id, distanceMeters: 5)
        return (
            BuildingGraph(zoneID: zone.id, nodes: [room, hall, exit], edges: [toHall, toExit]),
            room.id, toExit.id
        )
    }

    // MARK: - The message

    func testABlockedRouteIsNotBlamedOnAnAdministrator() {
        let text = RoutingError.allRoutesBlocked(blockedSegments: 1).localizedDescription
        XCTAssertFalse(
            text.lowercased().contains("administrator"),
            "a local map has no administrator; the only reporter is the user"
        )
        XCTAssertTrue(text.lowercased().contains("blocked"))
    }

    // MARK: - Reporting, then clearing

    func testReportingBlocksTheRouteAndClearingRestoresIt() throws {
        let (graph, roomID, exitEdgeID) = makeGraph()
        let start = RoutePosition(nodeID: roomID, worldPosition: .zero)

        // Before: the exit is reachable.
        let before = try ShortestPathService.findBestEgressRoute(
            from: start, graph: graph, profile: .standard
        )
        XCTAssertEqual(before.best.destination.name, "Game Room Exit")

        // The user says "the exit is blocked".
        var active = store.loadHazards(zone.id)
        active.set(RouteHazard(type: .blockedHallway, severity: 5), on: exitEdgeID)
        try store.saveHazards(active, zoneID: zone.id)

        let blocked = graph.applying(hazards: store.loadHazards(zone.id).hazards)
        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(
                from: start, graph: blocked, profile: .standard
            )
        ) { error in
            guard case RoutingError.allRoutesBlocked = error else {
                return XCTFail("expected allRoutesBlocked, got \(error)")
            }
        }

        // "It's open again" — and the route must come back.
        try store.clearHazards(zone.id)
        XCTAssertTrue(store.loadHazards(zone.id).hazards.isEmpty)

        let after = try ShortestPathService.findBestEgressRoute(
            from: start,
            graph: graph.applying(hazards: store.loadHazards(zone.id).hazards),
            profile: .standard
        )
        XCTAssertEqual(
            after.best.destination.name, "Game Room Exit",
            "clearing the report must make the exit usable again"
        )
    }

    func testClearingIsSafeWhenNothingWasReported() throws {
        XCTAssertNoThrow(try store.clearHazards(zone.id))
        XCTAssertTrue(store.loadHazards(zone.id).hazards.isEmpty)
    }

    // MARK: - The voice phrase

    func testReopeningPhrasesAreUnderstood() {
        let phrases = [
            "the exit is open again",
            "the hallway is clear now",
            "it's not blocked anymore",
            "the door is no longer blocked",
            "unblock the exit",
            "clear my report",
            "cancel my report",
            "all clear",
        ]
        for phrase in phrases {
            XCTAssertEqual(
                VoiceCommandParser.parse(phrase), .clearMyReports,
                "“\(phrase)” must be understood as reopening, not as a new hazard"
            )
        }
    }

    /// The clearing sense has to beat the hazard sense: "the exit is not
    /// blocked anymore" contains "blocked".
    func testReportingPhrasesStillRegisterAsHazards() {
        for phrase in ["the hallway is blocked", "there is fire ahead", "the door is locked"] {
            let parsed = VoiceCommandParser.parse(phrase)
            XCTAssertNotEqual(
                parsed, .clearMyReports,
                "“\(phrase)” is a report, not a clearing"
            )
            XCTAssertTrue(parsed.requiresConfirmation, "a report must still be confirmed")
        }
    }

    // MARK: - Destinations

    /// Emergency routes to exits only. Route testing may target anything —
    /// walking to a specific room is a normal thing to want.
    func testEmergencyRoutingOnlyEverTargetsExits() throws {
        let (graph, roomID, _) = makeGraph()
        let options = try ShortestPathService.findBestEgressRoute(
            from: RoutePosition(nodeID: roomID, worldPosition: .zero),
            graph: graph, profile: .standard
        )
        XCTAssertTrue(
            options.best.destination.type.isEgressTarget,
            "emergency egress must never finish somewhere that is not an exit"
        )
        for route in options.alternatives {
            XCTAssertTrue(route.destination.type.isEgressTarget)
        }
    }

    func testRouteTestingCanTargetANonExitRoom() throws {
        let (graph, roomID, _) = makeGraph()
        let hallway = try XCTUnwrap(graph.nodes.first { $0.type == .hallwayPoint })

        let route = try ShortestPathService.findRoute(
            from: RoutePosition(nodeID: roomID, worldPosition: .zero),
            to: hallway.id, graph: graph, profile: .standard
        )
        XCTAssertEqual(route.destination.id, hallway.id)
        XCTAssertFalse(route.destination.type.isEgressTarget)
    }

    /// With one exit and no refuge, a blocked route must fail rather than
    /// quietly finishing at some nearby room.
    func testASingleBlockedExitDoesNotFallBackToAnArbitraryRoom() throws {
        let (graph, roomID, exitEdgeID) = makeGraph()
        var blocked = graph
        blocked.edges = graph.edges.map {
            var edge = $0
            if edge.id == exitEdgeID { edge.isBlocked = true }
            return edge
        }

        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(
                from: RoutePosition(nodeID: roomID, worldPosition: .zero),
                graph: blocked, profile: .standard
            ),
            "there is no refuge and no second exit, so this must be an error"
        )
    }
}
