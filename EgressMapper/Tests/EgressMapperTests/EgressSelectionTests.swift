import XCTest
import simd
@testable import EgressMapper

/// Two exits from one intersection:
///   Room ── Intersection ── Stairwell ── East Exit   (near, stairs)
///                        └─ Elevator  ── West Exit   (far, step-free)
///                        └─ Refuge
private struct Building {
    let zoneID = UUID()
    let room: RouteNode
    let intersection: RouteNode
    let stairwell: RouteNode
    let eastExit: RouteNode
    let elevator: RouteNode
    let westExit: RouteNode
    let refuge: RouteNode
    var graph: BuildingGraph

    init() {
        func makeNode(_ name: String, _ type: RouteNodeType, x: Float, z: Float, zoneID: UUID) -> RouteNode {
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4<Float>(x, 1.4, z, 1)
            return RouteNode(name: name, type: type, position: CodableTransform(m), zoneID: zoneID)
        }

        let z = zoneID
        room = makeNode("Room 214", .room, x: 0, z: 0, zoneID: z)
        intersection = makeNode("Central Intersection", .intersection, x: 0, z: 10, zoneID: z)
        stairwell = makeNode("East Stairwell", .stairwell, x: 10, z: 10, zoneID: z)
        eastExit = makeNode("East Exit", .exit, x: 14, z: 10, zoneID: z)
        elevator = makeNode("Elevator", .elevator, x: -10, z: 10, zoneID: z)
        westExit = makeNode("West Exit", .exit, x: -40, z: 10, zoneID: z)
        refuge = makeNode("Refuge Area", .refugeArea, x: 0, z: 22, zoneID: z)

        graph = BuildingGraph(
            zoneID: z,
            nodes: [room, intersection, stairwell, eastExit, elevator, westExit, refuge],
            edges: [
                RouteEdge(fromNodeID: room.id, toNodeID: intersection.id, distanceMeters: 10),
                RouteEdge(fromNodeID: intersection.id, toNodeID: stairwell.id, distanceMeters: 10,
                          accessibility: .between(.intersection, .stairwell)),
                RouteEdge(fromNodeID: stairwell.id, toNodeID: eastExit.id, distanceMeters: 4,
                          accessibility: .between(.stairwell, .exit)),
                RouteEdge(fromNodeID: intersection.id, toNodeID: elevator.id, distanceMeters: 10,
                          accessibility: .between(.intersection, .elevator)),
                RouteEdge(fromNodeID: elevator.id, toNodeID: westExit.id, distanceMeters: 30,
                          accessibility: .between(.elevator, .exit)),
                RouteEdge(fromNodeID: intersection.id, toNodeID: refuge.id, distanceMeters: 12),
            ]
        )
    }

    var start: RoutePosition { RoutePosition(nodeID: room.id, worldPosition: room.worldPosition) }

    func edge(_ a: RouteNode, _ b: RouteNode) -> RouteEdge {
        graph.edges.first { $0.fromNodeID == a.id && $0.toNodeID == b.id }!
    }

    mutating func block(_ edge: RouteEdge) {
        graph.edges = graph.edges.map {
            guard $0.id == edge.id else { return $0 }
            var blocked = $0
            blocked.isBlocked = true
            return blocked
        }
    }
}

final class AutomaticExitSelectionTests: XCTestCase {

    func testPicksNearestReachableExitWithoutBeingTold() throws {
        let b = Building()
        let options = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .standard
        )
        XCTAssertEqual(options.best.destination.name, "East Exit")
        XCTAssertEqual(options.best.totalDistanceMeters, 24, accuracy: 0.01)
    }

    func testAlternativesAreRankedAndExcludeTheChosenExit() throws {
        let b = Building()
        let options = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .standard
        )
        XCTAssertEqual(options.alternatives.map(\.destination.name), ["West Exit"])
        XCTAssertFalse(options.alternatives.contains { $0.destination.id == options.best.destination.id })
    }

    func testBlockedExitIsReportedAsUnreachableNotSilentlyDropped() throws {
        var b = Building()
        b.block(b.edge(b.intersection, b.stairwell))

        let options = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .standard
        )
        XCTAssertEqual(options.best.destination.name, "West Exit")
        XCTAssertEqual(options.unreachable.map(\.node.name), ["East Exit"])
        XCTAssertFalse(options.unreachable[0].reason.isEmpty)
    }

    func testSummaryNamesTheChoiceAndTheUnavailableExit() throws {
        var b = Building()
        b.block(b.edge(b.intersection, b.stairwell))

        let options = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .standard
        )
        // e.g. "Routing to West Exit — 50 m. East Exit is unavailable."
        XCTAssertTrue(options.summary.contains("West Exit"))
        XCTAssertTrue(options.summary.contains("East Exit is unavailable"))
    }

    func testSummaryPluralisesMultipleUnavailableExits() throws {
        var b = Building()
        b.block(b.edge(b.intersection, b.stairwell))
        b.block(b.edge(b.intersection, b.elevator))

        let options = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .standard
        )
        XCTAssertTrue(options.best.isRefugeFallback)
        XCTAssertEqual(options.unreachable.count, 2)
        XCTAssertTrue(options.summary.contains("are unavailable"))
    }

    func testNoExitsAtAllThrowsRatherThanReturningEmpty() {
        var b = Building()
        let exitIDs = Set([b.eastExit.id, b.westExit.id, b.refuge.id])
        b.graph.nodes.removeAll { exitIDs.contains($0.id) }
        b.graph.edges.removeAll { exitIDs.contains($0.fromNodeID) || exitIDs.contains($0.toNodeID) }

        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(from: b.start, graph: b.graph, profile: .standard)
        ) { XCTAssertEqual($0 as? RoutingError, .noRoute) }
    }

    func testWorksFromAMidHallwayPosition() throws {
        let b = Building()
        let edge = b.edge(b.room, b.intersection)
        let start = RoutePosition(
            edgeID: edge.id, fractionAlongEdge: 0.5,
            worldPosition: SIMD3<Float>(0, 1.4, 5)
        )
        let options = try ShortestPathService.findBestEgressRoute(
            from: start, graph: b.graph, profile: .standard
        )
        XCTAssertEqual(options.best.destination.name, "East Exit")
        XCTAssertEqual(options.best.nodes.first?.type, .temporaryStart)
        XCTAssertEqual(options.best.totalDistanceMeters, 19, accuracy: 0.01)
    }
}

final class AccessibilityReroutingTests: XCTestCase {

    func testAccessibleProfileSwitchesAwayFromTheStairExit() throws {
        let b = Building()

        let standard = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .standard
        )
        XCTAssertEqual(standard.best.destination.name, "East Exit")

        // The user taps "I Need an Accessible Route" mid-navigation.
        let accessible = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .wheelchair
        )
        XCTAssertEqual(accessible.best.destination.name, "West Exit")
        XCTAssertTrue(accessible.best.edges.allSatisfy { $0.accessibility.wheelchairAccessible })
        XCTAssertNotEqual(standard.best.destination.id, accessible.best.destination.id)
    }

    func testAccessibleRouteIsLongerButValid() throws {
        let b = Building()
        let standard = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .standard
        )
        let accessible = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .wheelchair
        )
        XCTAssertGreaterThan(
            accessible.best.totalDistanceMeters, standard.best.totalDistanceMeters,
            "The step-free route here is genuinely longer — that is correct, not a bug"
        )
    }

    func testStairExitBecomesUnreachableUnderAccessibleProfile() throws {
        let b = Building()
        let options = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .wheelchair
        )
        XCTAssertEqual(options.unreachable.map(\.node.name), ["East Exit"])
    }

    func testExplanationStatesTheConstraint() throws {
        let b = Building()
        let options = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .wheelchair
        )
        XCTAssertTrue(options.best.explanation.contains("wheelchair accessible"))
    }

    func testAccessibleUserWithNoStepFreeExitGetsRefugeNotStairs() throws {
        var b = Building()
        // Elevator branch blocked: the only remaining exit needs stairs.
        b.block(b.edge(b.intersection, b.elevator))

        let options = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .wheelchair
        )
        XCTAssertTrue(options.best.isRefugeFallback)
        XCTAssertEqual(options.best.destination.name, "Refuge Area")
        XCTAssertFalse(
            options.best.edges.contains { $0.accessibility.containsStairs },
            "A wheelchair user must never be routed down stairs, even as a fallback"
        )
    }

    func testRevertingToStandardProfileRestoresTheShorterRoute() throws {
        let b = Building()
        let accessible = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .wheelchair
        )
        let reverted = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .standard
        )
        XCTAssertEqual(accessible.best.destination.name, "West Exit")
        XCTAssertEqual(reverted.best.destination.name, "East Exit")
    }

    func testProfilePersistsAcrossStoreReload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EgressProfile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ZoneFileStore(root: root)
        try store.saveProfile(.wheelchair)

        let reloaded = ZoneFileStore(root: root).loadProfile()
        XCTAssertTrue(reloaded.avoidStairs)
        XCTAssertTrue(reloaded.requireWheelchairAccessible)
    }
}
