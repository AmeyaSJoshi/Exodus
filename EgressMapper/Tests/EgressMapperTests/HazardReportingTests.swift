import XCTest
import simd
@testable import EgressMapper

/// Room ── Intersection ── Stairwell ── East Exit
///                      └─ Hall ────── West Exit
private struct TwoWayBuilding {
    let zoneID = UUID()
    let room: RouteNode
    let intersection: RouteNode
    let stairwell: RouteNode
    let eastExit: RouteNode
    let hall: RouteNode
    let westExit: RouteNode
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
        hall = makeNode("West Hall", .hallwayPoint, x: -10, z: 10, zoneID: z)
        westExit = makeNode("West Exit", .exit, x: -30, z: 10, zoneID: z)

        graph = BuildingGraph(
            zoneID: z,
            nodes: [room, intersection, stairwell, eastExit, hall, westExit],
            edges: [
                RouteEdge(fromNodeID: room.id, toNodeID: intersection.id, distanceMeters: 10),
                RouteEdge(fromNodeID: intersection.id, toNodeID: stairwell.id, distanceMeters: 10),
                RouteEdge(fromNodeID: stairwell.id, toNodeID: eastExit.id, distanceMeters: 4),
                RouteEdge(fromNodeID: intersection.id, toNodeID: hall.id, distanceMeters: 10),
                RouteEdge(fromNodeID: hall.id, toNodeID: westExit.id, distanceMeters: 20),
            ]
        )
    }

    var start: RoutePosition { RoutePosition(nodeID: room.id, worldPosition: room.worldPosition) }

    func edge(_ a: RouteNode, _ b: RouteNode) -> RouteEdge {
        graph.edges.first { $0.fromNodeID == a.id && $0.toNodeID == b.id }!
    }
}

final class HazardReroutingTests: XCTestCase {

    func testBlockingTheRouteAheadSelectsADifferentExit() throws {
        let b = TwoWayBuilding()

        let before = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph, profile: .standard
        )
        XCTAssertEqual(before.best.destination.name, "East Exit")

        var active = ActiveHazards(zoneID: b.zoneID)
        active.set(RouteHazard(type: .blockedHallway), on: b.edge(b.intersection, b.stairwell).id)

        let after = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph.applying(hazards: active.hazards), profile: .standard
        )
        XCTAssertEqual(after.best.destination.name, "West Exit")
        XCTAssertNotEqual(before.best.destination.id, after.best.destination.id)
    }

    func testBlockedEdgeNeverAppearsInTheReplacementRoute() throws {
        let b = TwoWayBuilding()
        let blocked = b.edge(b.intersection, b.stairwell)

        var active = ActiveHazards(zoneID: b.zoneID)
        active.set(RouteHazard(type: .fire), on: blocked.id)

        let after = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph.applying(hazards: active.hazards), profile: .standard
        )
        XCTAssertFalse(after.best.edges.contains { $0.id == blocked.id })
        XCTAssertFalse(after.best.nodes.contains { $0.id == b.stairwell.id })
    }

    func testEachBlockingHazardTypeRemovesTheSegment() throws {
        for type in RouteHazardType.allCases where type.blocksTravel {
            let b = TwoWayBuilding()
            var active = ActiveHazards(zoneID: b.zoneID)
            active.set(RouteHazard(type: type), on: b.edge(b.intersection, b.stairwell).id)

            let after = try ShortestPathService.findBestEgressRoute(
                from: b.start, graph: b.graph.applying(hazards: active.hazards), profile: .standard
            )
            XCTAssertEqual(after.best.destination.name, "West Exit", "failed for \(type.rawValue)")
        }
    }

    func testSmokeIsAvoidedButNotTreatedAsImpassable() throws {
        let b = TwoWayBuilding()
        var active = ActiveHazards(zoneID: b.zoneID)
        active.set(RouteHazard(type: .smoke, severity: 5), on: b.edge(b.intersection, b.stairwell).id)

        let hazarded = b.graph.applying(hazards: active.hazards)
        let smokeEdge = hazarded.edges.first { $0.id == b.edge(b.intersection, b.stairwell).id }!

        XCTAssertFalse(smokeEdge.isBlocked, "Smoke must not hard-block the segment")
        XCTAssertGreaterThan(smokeEdge.hazardPenalty, 1)

        // The penalty should still push the route the other way.
        let after = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: hazarded, profile: .standard
        )
        XCTAssertEqual(after.best.destination.name, "West Exit")
    }

    func testClearingTheHazardRestoresTheOriginalExit() throws {
        let b = TwoWayBuilding()
        var active = ActiveHazards(zoneID: b.zoneID)
        let edgeID = b.edge(b.intersection, b.stairwell).id

        active.set(RouteHazard(type: .blockedHallway), on: edgeID)
        XCTAssertEqual(
            try ShortestPathService.findBestEgressRoute(
                from: b.start, graph: b.graph.applying(hazards: active.hazards), profile: .standard
            ).best.destination.name,
            "West Exit"
        )

        active.clear(edgeID)
        XCTAssertEqual(
            try ShortestPathService.findBestEgressRoute(
                from: b.start, graph: b.graph.applying(hazards: active.hazards), profile: .standard
            ).best.destination.name,
            "East Exit"
        )
    }

    func testBlockingEveryPathFailsHonestly() {
        let b = TwoWayBuilding()
        var active = ActiveHazards(zoneID: b.zoneID)
        active.set(RouteHazard(type: .fire), on: b.edge(b.intersection, b.stairwell).id)
        active.set(RouteHazard(type: .fire), on: b.edge(b.intersection, b.hall).id)

        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(
                from: b.start, graph: b.graph.applying(hazards: active.hazards), profile: .standard
            )
        ) { error in
            guard case RoutingError.allRoutesBlocked = error else {
                return XCTFail("expected allRoutesBlocked, got \(error)")
            }
        }
    }

    func testHazardAndAccessibilityConstraintsCombine() throws {
        var b = TwoWayBuilding()
        // Make the east branch stair-based.
        b.graph.edges = b.graph.edges.map { e in
            guard e.toNodeID == b.stairwell.id || e.fromNodeID == b.stairwell.id else { return e }
            var updated = e
            updated.accessibility = .between(.intersection, .stairwell)
            return updated
        }

        var active = ActiveHazards(zoneID: b.zoneID)
        active.set(RouteHazard(type: .blockedHallway), on: b.edge(b.intersection, b.hall).id)

        // West blocked by hazard, east excluded by profile -> nothing left.
        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(
                from: b.start, graph: b.graph.applying(hazards: active.hazards), profile: .wheelchair
            )
        ) { error in
            guard case RoutingError.noAccessibleRoute = error else {
                return XCTFail("Expected .noAccessibleRoute, got \(error)")
            }
        }
    }

    func testUnreachableExitReportsTheHazardAsTheReason() throws {
        let b = TwoWayBuilding()
        var active = ActiveHazards(zoneID: b.zoneID)
        active.set(RouteHazard(type: .fire), on: b.edge(b.intersection, b.stairwell).id)

        let options = try ShortestPathService.findBestEgressRoute(
            from: b.start, graph: b.graph.applying(hazards: active.hazards), profile: .standard
        )
        XCTAssertEqual(options.unreachable.map(\.node.name), ["East Exit"])
        XCTAssertTrue(options.summary.contains("East Exit is unavailable"))
    }
}

final class HazardPersistenceTests: XCTestCase {
    private var root: URL!
    private var store: ZoneFileStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EgressHazards-\(UUID().uuidString)", isDirectory: true)
        store = ZoneFileStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testHazardsSurviveReload() throws {
        let b = TwoWayBuilding()
        let edgeID = b.graph.edges[0].id
        var active = ActiveHazards(zoneID: b.zoneID)
        active.set(RouteHazard(type: .smoke, description: "Thick smoke", severity: 4), on: edgeID)
        try store.saveHazards(active, zoneID: b.zoneID)

        let reloaded = ZoneFileStore(root: root).loadHazards(b.zoneID)
        XCTAssertEqual(reloaded.hazards.count, 1)
        XCTAssertEqual(reloaded.hazards[edgeID]?.type, .smoke)
        XCTAssertEqual(reloaded.hazards[edgeID]?.severity, 4)
        XCTAssertEqual(reloaded.hazards[edgeID]?.description, "Thick smoke")
    }

    func testPermanentGraphIsNeverMutatedByHazards() throws {
        let b = TwoWayBuilding()
        try store.saveGraph(b.graph, zoneID: b.zoneID)

        var active = ActiveHazards(zoneID: b.zoneID)
        active.set(RouteHazard(type: .fire), on: b.graph.edges[0].id)
        try store.saveHazards(active, zoneID: b.zoneID)
        _ = b.graph.applying(hazards: active.hazards)

        let reloadedGraph = try XCTUnwrap(store.loadGraph(b.zoneID))
        XCTAssertFalse(reloadedGraph.edges.contains { $0.isBlocked })
        XCTAssertFalse(reloadedGraph.edges.contains { $0.hazard != nil })
    }

    func testClearingOneHazardLeavesOthers() throws {
        let b = TwoWayBuilding()
        let first = b.graph.edges[0].id
        let second = b.graph.edges[1].id

        var active = ActiveHazards(zoneID: b.zoneID)
        active.set(RouteHazard(type: .smoke), on: first)
        active.set(RouteHazard(type: .fire), on: second)
        try store.saveHazards(active, zoneID: b.zoneID)

        active.clear(first)
        try store.saveHazards(active, zoneID: b.zoneID)

        let reloaded = store.loadHazards(b.zoneID)
        XCTAssertNil(reloaded.hazards[first])
        XCTAssertNotNil(reloaded.hazards[second])
    }

    func testCorruptedHazardFileDegradesToEmpty() throws {
        let zoneID = UUID()
        try store.saveZone(MappingZone(id: zoneID, campus: "C", building: "B", floor: "1", zoneName: "Z"))
        try Data("{ not json".utf8).write(to: store.url(zoneID, "hazards.json"))
        XCTAssertTrue(store.loadHazards(zoneID).isEmpty, "A corrupt hazard file must not block evacuation")
    }

    func testClearAllEmptiesEverything() throws {
        let b = TwoWayBuilding()
        var active = ActiveHazards(zoneID: b.zoneID)
        active.set(RouteHazard(type: .fire), on: b.graph.edges[0].id)
        active.set(RouteHazard(type: .smoke), on: b.graph.edges[1].id)
        try store.saveHazards(active, zoneID: b.zoneID)

        active.clearAll()
        try store.saveHazards(active, zoneID: b.zoneID)
        XCTAssertTrue(store.loadHazards(b.zoneID).isEmpty)
    }
}
