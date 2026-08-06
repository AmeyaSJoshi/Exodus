import XCTest
import simd
@testable import EgressMapper

// MARK: - Fixtures

private func transform(x: Float, z: Float, y: Float = 1.4) -> CodableTransform {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(x, y, z, 1)
    return CodableTransform(m)
}

private func node(
    _ name: String, _ type: RouteNodeType, x: Float, z: Float, zoneID: UUID
) -> RouteNode {
    RouteNode(name: name, type: type, position: transform(x: x, z: z), zoneID: zoneID)
}

private func waypoint(
    _ name: String, _ type: WaypointType, x: Float, z: Float, index: Int, zoneID: UUID
) -> Waypoint {
    Waypoint(
        zoneID: zoneID, name: name, type: type, anchorID: UUID(),
        transform: transform(x: x, z: z), pathIndex: index
    )
}

/// Room → Intersection → Stairwell → Exit(east), plus an accessible
/// Elevator → Exit(west) branch off the intersection.
private struct Fixture {
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
        let z = zoneID
        room = node("Room 214", .room, x: 0, z: 0, zoneID: z)
        intersection = node("Central Intersection", .intersection, x: 0, z: 10, zoneID: z)
        stairwell = node("East Stairwell", .stairwell, x: 10, z: 10, zoneID: z)
        eastExit = node("East Exit", .exit, x: 15, z: 10, zoneID: z)
        elevator = node("Elevator", .elevator, x: -10, z: 10, zoneID: z)
        westExit = node("West Exit", .exit, x: -30, z: 10, zoneID: z)
        refuge = node("Refuge Area", .refugeArea, x: 0, z: 20, zoneID: z)

        let nodes = [room, intersection, stairwell, eastExit, elevator, westExit, refuge]
        let edges = [
            RouteEdge(fromNodeID: room.id, toNodeID: intersection.id,
                      distanceMeters: 10, accessibility: .standard),
            RouteEdge(fromNodeID: intersection.id, toNodeID: stairwell.id,
                      distanceMeters: 10,
                      accessibility: .between(.intersection, .stairwell)),
            RouteEdge(fromNodeID: stairwell.id, toNodeID: eastExit.id,
                      distanceMeters: 5,
                      accessibility: .between(.stairwell, .exit)),
            RouteEdge(fromNodeID: intersection.id, toNodeID: elevator.id,
                      distanceMeters: 10,
                      accessibility: .between(.intersection, .elevator)),
            RouteEdge(fromNodeID: elevator.id, toNodeID: westExit.id,
                      distanceMeters: 20,
                      accessibility: .between(.elevator, .exit)),
            RouteEdge(fromNodeID: intersection.id, toNodeID: refuge.id,
                      distanceMeters: 10, accessibility: .standard),
        ]
        graph = BuildingGraph(zoneID: z, nodes: nodes, edges: edges)
    }

    func start() -> RoutePosition {
        RoutePosition(nodeID: room.id, worldPosition: room.worldPosition)
    }

    func edge(from a: RouteNode, to b: RouteNode) -> RouteEdge {
        graph.edges.first { ($0.fromNodeID == a.id && $0.toNodeID == b.id) }!
    }
}

// MARK: - Migration

final class GraphMigrationTests: XCTestCase {

    private func legacyZone() -> (UUID, [Waypoint], RoutePath) {
        let zoneID = UUID()
        let waypoints = [
            waypoint("Room 214", .room, x: 0, z: 0, index: 0, zoneID: zoneID),
            waypoint("Intersection", .intersection, x: 0, z: 10, index: 10, zoneID: zoneID),
            waypoint("Stair A", .stairwell, x: 10, z: 10, index: 20, zoneID: zoneID),
            waypoint("Exit A", .exit, x: 15, z: 10, index: 25, zoneID: zoneID),
        ]
        var path = RoutePath()
        for i in 0...10 { path.append(SIMD3<Float>(0, 1.4, Float(i)), at: TimeInterval(i)) }
        for i in 1...15 { path.append(SIMD3<Float>(Float(i), 1.4, 10), at: TimeInterval(10 + i)) }
        return (zoneID, waypoints, path)
    }

    func testLegacyWaypointsBecomeGraphNodes() {
        let (zoneID, waypoints, path) = legacyZone()
        let graph = GraphMigrator.migrate(zoneID: zoneID, waypoints: waypoints, path: path)

        XCTAssertEqual(graph.nodes.count, 4)
        XCTAssertEqual(graph.edges.count, 3)
        XCTAssertEqual(graph.version, BuildingGraph.currentVersion)
        XCTAssertEqual(graph.exits.count, 1)
        XCTAssertEqual(graph.exits.first?.name, "Exit A")
    }

    func testMigrationPreservesWaypointIDsSoARAnchorsStillResolve() {
        let (zoneID, waypoints, path) = legacyZone()
        let graph = GraphMigrator.migrate(zoneID: zoneID, waypoints: waypoints, path: path)
        for w in waypoints {
            XCTAssertNotNil(graph.node(w.id), "Node id must equal the source waypoint id")
        }
    }

    func testMigrationDerivesStairAccessibility() {
        let (zoneID, waypoints, path) = legacyZone()
        let graph = GraphMigrator.migrate(zoneID: zoneID, waypoints: waypoints, path: path)

        let stairEdges = graph.edges.filter { $0.accessibility.containsStairs }
        XCTAssertEqual(stairEdges.count, 2, "Both edges touching the stairwell involve stairs")
        for edge in stairEdges {
            XCTAssertFalse(edge.accessibility.wheelchairAccessible)
        }
    }

    func testMigrationUsesWalkedDistanceNotStraightLine() {
        let (zoneID, waypoints, path) = legacyZone()
        let graph = GraphMigrator.migrate(zoneID: zoneID, waypoints: waypoints, path: path)

        // Room -> Intersection is a straight 10 m walk.
        let first = graph.edges.first { $0.fromNodeID == waypoints[0].id }
        XCTAssertEqual(first?.distanceMeters ?? 0, 10, accuracy: 0.2)
    }

    func testResolveRebuildsWhenNoStoredGraph() {
        let (zoneID, waypoints, path) = legacyZone()
        let resolved = GraphMigrator.resolve(stored: nil, zoneID: zoneID, waypoints: waypoints, path: path)
        XCTAssertTrue(resolved.didMigrate)
        XCTAssertEqual(resolved.graph.nodes.count, 4)
    }

    func testResolveKeepsCurrentStoredGraph() {
        let (zoneID, waypoints, path) = legacyZone()
        let built = GraphMigrator.migrate(zoneID: zoneID, waypoints: waypoints, path: path)
        let resolved = GraphMigrator.resolve(stored: built, zoneID: zoneID, waypoints: waypoints, path: path)
        XCTAssertFalse(resolved.didMigrate)
    }

    func testResolveRebuildsStaleVersion() {
        let (zoneID, waypoints, path) = legacyZone()
        var stale = GraphMigrator.migrate(zoneID: zoneID, waypoints: waypoints, path: path)
        stale.version = 0
        let resolved = GraphMigrator.resolve(stored: stale, zoneID: zoneID, waypoints: waypoints, path: path)
        XCTAssertTrue(resolved.didMigrate)
        XCTAssertEqual(resolved.graph.version, BuildingGraph.currentVersion)
    }

    func testSingleWaypointProducesNodeButNoEdges() {
        let zoneID = UUID()
        let graph = GraphMigrator.migrate(
            zoneID: zoneID,
            waypoints: [waypoint("Solo", .room, x: 0, z: 0, index: 0, zoneID: zoneID)],
            path: RoutePath()
        )
        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertTrue(graph.edges.isEmpty)
    }
}

// MARK: - Routing

final class ShortestPathServiceTests: XCTestCase {

    func testRoutesToNearestExit() throws {
        let f = Fixture()
        let result = try ShortestPathService.findBestEgressRoute(
            from: f.start(), graph: f.graph, profile: .standard
        )
        XCTAssertEqual(result.best.destination.name, "East Exit")
        XCTAssertEqual(result.best.totalDistanceMeters, 25, accuracy: 0.01)
        XCTAssertFalse(result.alternatives.isEmpty)
    }

    func testBlockedEdgeIsExcludedAndNextExitChosen() throws {
        var f = Fixture()
        let stairEdge = f.edge(from: f.intersection, to: f.stairwell)
        f.graph.edges = f.graph.edges.map { e in
            guard e.id == stairEdge.id else { return e }
            var blocked = e
            blocked.isBlocked = true
            return blocked
        }

        let result = try ShortestPathService.findBestEgressRoute(
            from: f.start(), graph: f.graph, profile: .standard
        )
        XCTAssertEqual(result.best.destination.name, "West Exit")
        XCTAssertFalse(
            result.best.edges.contains { $0.id == stairEdge.id },
            "A blocked edge must never appear in a route"
        )
    }

    func testAvoidStairsExcludesStairEdges() throws {
        let f = Fixture()
        let profile = NavigationProfile(avoidStairs: true)
        let result = try ShortestPathService.findBestEgressRoute(
            from: f.start(), graph: f.graph, profile: profile
        )
        XCTAssertEqual(result.best.destination.name, "West Exit")
        XCTAssertFalse(result.best.edges.contains { $0.accessibility.containsStairs })
    }

    func testWheelchairProfileExcludesInaccessibleEdges() throws {
        let f = Fixture()
        let result = try ShortestPathService.findBestEgressRoute(
            from: f.start(), graph: f.graph, profile: .wheelchair
        )
        XCTAssertTrue(result.best.edges.allSatisfy { $0.accessibility.wheelchairAccessible })
    }

    func testAvoidElevatorsExcludesElevatorRoutes() throws {
        let f = Fixture()
        let profile = NavigationProfile(avoidElevators: true)
        let result = try ShortestPathService.findBestEgressRoute(
            from: f.start(), graph: f.graph, profile: profile
        )
        XCTAssertFalse(result.best.edges.contains { $0.accessibility.requiresElevator })
        XCTAssertEqual(result.best.destination.name, "East Exit")
    }

    func testConflictingConstraintsFallBackToRefugeRatherThanStranding() throws {
        let f = Fixture()
        // Stairs banned AND elevators banned -> no exit is reachable, but the
        // area of refuge is. Sheltering beats stranding the user.
        let profile = NavigationProfile(avoidStairs: true, avoidElevators: true)
        let result = try ShortestPathService.findBestEgressRoute(
            from: f.start(), graph: f.graph, profile: profile
        )
        XCTAssertTrue(result.best.isRefugeFallback)
        XCTAssertEqual(result.best.destination.name, "Refuge Area")
    }

    func testNoExitAndNoRefugeFailsLoudlyWithAccessibilityReason() {
        var f = Fixture()
        // Remove the refuge so there is genuinely nowhere accessible to go.
        let refugeID = f.refuge.id
        f.graph.nodes.removeAll { $0.id == refugeID }
        f.graph.edges.removeAll { $0.toNodeID == refugeID || $0.fromNodeID == refugeID }

        let profile = NavigationProfile(avoidStairs: true, avoidElevators: true)
        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(from: f.start(), graph: f.graph, profile: profile)
        ) { error in
            guard case RoutingError.noAccessibleRoute = error else {
                return XCTFail("Expected .noAccessibleRoute, got \(error)")
            }
        }
    }

    func testFallsBackToRefugeWhenNoExitReachable() throws {
        var f = Fixture()
        // Block both exit branches, leaving only the refuge.
        let blockedIDs = Set([
            f.edge(from: f.intersection, to: f.stairwell).id,
            f.edge(from: f.intersection, to: f.elevator).id,
        ])
        f.graph.edges = f.graph.edges.map { e in
            guard blockedIDs.contains(e.id) else { return e }
            var blocked = e
            blocked.isBlocked = true
            return blocked
        }

        let result = try ShortestPathService.findBestEgressRoute(
            from: f.start(), graph: f.graph, profile: .standard
        )
        XCTAssertTrue(result.best.isRefugeFallback)
        XCTAssertEqual(result.best.destination.name, "Refuge Area")
        XCTAssertTrue(result.best.explanation.contains("refuge"))
    }

    func testFullyBlockedGraphThrowsNoRoute() {
        var f = Fixture()
        f.graph.edges = f.graph.edges.map { e in
            var blocked = e
            blocked.isBlocked = true
            return blocked
        }
        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(from: f.start(), graph: f.graph, profile: .standard)
        ) { error in
            XCTAssertEqual(error as? RoutingError, .noRoute)
        }
    }

    func testNonBlockingHazardPenalisesButKeepsRoute() throws {
        var f = Fixture()
        let stairEdge = f.edge(from: f.intersection, to: f.stairwell)
        f.graph.edges = f.graph.edges.map { e in
            guard e.id == stairEdge.id else { return e }
            var hazarded = e
            hazarded.hazard = RouteHazard(type: .smoke, severity: 5)
            return hazarded
        }
        // Smoke does not block, but the penalty should push routing west.
        let result = try ShortestPathService.findBestEgressRoute(
            from: f.start(), graph: f.graph, profile: .standard
        )
        XCTAssertEqual(result.best.destination.name, "West Exit")
        XCTAssertFalse(result.best.edges.isEmpty)
    }

    func testUnknownStartThrows() {
        let f = Fixture()
        let bogus = RoutePosition(nodeID: UUID(), worldPosition: .zero)
        XCTAssertThrowsError(
            try ShortestPathService.findRoute(
                from: bogus, to: f.eastExit.id, graph: f.graph, profile: .standard
            )
        ) { XCTAssertEqual($0 as? RoutingError, .unknownStart) }
    }

    func testUnknownDestinationThrows() {
        let f = Fixture()
        XCTAssertThrowsError(
            try ShortestPathService.findRoute(
                from: f.start(), to: UUID(), graph: f.graph, profile: .standard
            )
        ) { XCTAssertEqual($0 as? RoutingError, .unknownDestination) }
    }

    func testEmptyGraphThrows() {
        let empty = BuildingGraph(zoneID: UUID(), nodes: [], edges: [])
        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(
                from: RoutePosition(nodeID: UUID(), worldPosition: .zero),
                graph: empty, profile: .standard
            )
        ) { XCTAssertEqual($0 as? RoutingError, .emptyGraph) }
    }

    func testBlockedEdgeIsNotTraversableRegardlessOfProfile() {
        var edge = RouteEdge(fromNodeID: UUID(), toNodeID: UUID(), distanceMeters: 1)
        edge.isBlocked = true
        XCTAssertFalse(ShortestPathService.isTraversable(edge, profile: .standard))
        XCTAssertFalse(ShortestPathService.isTraversable(edge, profile: .wheelchair))
    }

    func testExplanationMentionsConstraints() {
        let f = Fixture()
        let text = ShortestPathService.explanation(
            to: f.westExit, distance: 64, profile: NavigationProfile(avoidStairs: true)
        )
        XCTAssertTrue(text.contains("West Exit"))
        XCTAssertTrue(text.contains("64"))
        XCTAssertTrue(text.contains("avoiding stairs"))
    }
}

// MARK: - Temporary start node

final class TemporaryStartNodeTests: XCTestCase {

    func testInsertionSplitsCorrectEdge() throws {
        let f = Fixture()
        let target = f.edge(from: f.room, to: f.intersection)

        let inserted = try XCTUnwrap(
            f.graph.insertingTemporaryStart(onEdge: target.id, fraction: 0.5)
        )
        let temp = try XCTUnwrap(inserted.graph.node(inserted.startNodeID))
        XCTAssertEqual(temp.type, .temporaryStart)

        let newEdges = inserted.graph.edges.filter {
            $0.fromNodeID == temp.id || $0.toNodeID == temp.id
        }
        XCTAssertEqual(newEdges.count, 2, "The edge must split into exactly two")
        for e in newEdges {
            XCTAssertEqual(e.distanceMeters, target.distanceMeters / 2, accuracy: 0.001)
        }
    }

    func testInsertionPositionsNodeAtFractionAlongEdge() throws {
        let f = Fixture()
        let target = f.edge(from: f.room, to: f.intersection)  // (0,0) -> (0,10)
        let inserted = try XCTUnwrap(
            f.graph.insertingTemporaryStart(onEdge: target.id, fraction: 0.25)
        )
        let temp = try XCTUnwrap(inserted.graph.node(inserted.startNodeID))
        XCTAssertEqual(temp.worldPosition.z, 2.5, accuracy: 0.001)
    }

    func testInsertionDoesNotMutatePermanentGraph() throws {
        let f = Fixture()
        let originalNodeCount = f.graph.nodes.count
        let originalEdgeCount = f.graph.edges.count
        let target = f.edge(from: f.room, to: f.intersection)

        _ = f.graph.insertingTemporaryStart(onEdge: target.id, fraction: 0.5)

        XCTAssertEqual(f.graph.nodes.count, originalNodeCount, "Saved graph must be untouched")
        XCTAssertEqual(f.graph.edges.count, originalEdgeCount)
    }

    func testRemovingTemporaryDataRestoresOriginalShape() throws {
        let f = Fixture()
        let target = f.edge(from: f.room, to: f.intersection)
        let inserted = try XCTUnwrap(
            f.graph.insertingTemporaryStart(onEdge: target.id, fraction: 0.5)
        )
        let cleaned = inserted.graph.removingTemporaryData()
        XCTAssertEqual(cleaned.nodes.count, f.graph.nodes.count)
        XCTAssertEqual(cleaned.edges.count, f.graph.edges.count)
        XCTAssertFalse(cleaned.nodes.contains { $0.type == .temporaryStart })
    }

    func testRoutingFromMidEdgePositionWorks() throws {
        let f = Fixture()
        let target = f.edge(from: f.room, to: f.intersection)
        let start = RoutePosition(
            edgeID: target.id, fractionAlongEdge: 0.5,
            worldPosition: SIMD3<Float>(0, 1.4, 5)
        )
        let route = try ShortestPathService.findRoute(
            from: start, to: f.eastExit.id, graph: f.graph, profile: .standard
        )
        XCTAssertEqual(route.nodes.first?.type, .temporaryStart)
        XCTAssertEqual(route.destination.name, "East Exit")
        // 5 m remaining on the split edge + 10 + 5.
        XCTAssertEqual(route.totalDistanceMeters, 20, accuracy: 0.01)
    }

    func testInsertionOnUnknownEdgeReturnsNil() {
        let f = Fixture()
        XCTAssertNil(f.graph.insertingTemporaryStart(onEdge: UUID(), fraction: 0.5))
    }

    func testFractionIsClamped() throws {
        let f = Fixture()
        let target = f.edge(from: f.room, to: f.intersection)
        let inserted = try XCTUnwrap(
            f.graph.insertingTemporaryStart(onEdge: target.id, fraction: 5.0)
        )
        let temp = try XCTUnwrap(inserted.graph.node(inserted.startNodeID))
        XCTAssertEqual(temp.worldPosition.z, 10, accuracy: 0.001)
    }
}

// MARK: - Hazards

final class HazardApplicationTests: XCTestCase {

    func testApplyingBlockingHazardRemovesEdgeFromRoutes() throws {
        let f = Fixture()
        let stairEdge = f.edge(from: f.intersection, to: f.stairwell)

        var active = ActiveHazards(zoneID: f.zoneID)
        active.set(RouteHazard(type: .blockedHallway), on: stairEdge.id)

        let hazarded = f.graph.applying(hazards: active.hazards)
        let route = try ShortestPathService.findBestEgressRoute(
            from: f.start(), graph: hazarded, profile: .standard
        )
        XCTAssertEqual(route.best.destination.name, "West Exit")
    }

    func testClearingHazardRestoresOriginalRoute() throws {
        let f = Fixture()
        let stairEdge = f.edge(from: f.intersection, to: f.stairwell)

        var active = ActiveHazards(zoneID: f.zoneID)
        active.set(RouteHazard(type: .fire), on: stairEdge.id)
        let blockedRoute = try ShortestPathService.findBestEgressRoute(
            from: f.start(), graph: f.graph.applying(hazards: active.hazards), profile: .standard
        )
        XCTAssertEqual(blockedRoute.best.destination.name, "West Exit")

        active.clear(stairEdge.id)
        let restored = try ShortestPathService.findBestEgressRoute(
            from: f.start(), graph: f.graph.applying(hazards: active.hazards), profile: .standard
        )
        XCTAssertEqual(restored.best.destination.name, "East Exit")
    }

    func testApplyingHazardsDoesNotMutatePermanentGraph() {
        let f = Fixture()
        let stairEdge = f.edge(from: f.intersection, to: f.stairwell)
        var active = ActiveHazards(zoneID: f.zoneID)
        active.set(RouteHazard(type: .fire), on: stairEdge.id)

        _ = f.graph.applying(hazards: active.hazards)

        XCTAssertFalse(
            f.graph.edges.contains { $0.isBlocked || $0.hazard != nil },
            "The permanent graph must never gain hazards"
        )
    }

    func testSmokeDoesNotBlockButFireDoes() {
        XCTAssertFalse(RouteHazardType.smoke.blocksTravel)
        XCTAssertTrue(RouteHazardType.fire.blocksTravel)
        XCTAssertTrue(RouteHazardType.lockedDoor.blocksTravel)
        XCTAssertFalse(RouteHazardType.other.blocksTravel)
    }

    func testHazardSeverityIsClamped() {
        XCTAssertEqual(RouteHazard(type: .smoke, severity: 99).severity, 5)
        XCTAssertEqual(RouteHazard(type: .smoke, severity: -4).severity, 1)
    }
}

// MARK: - Persistence

final class GraphStorageTests: XCTestCase {
    private var tempRoot: URL!
    private var store: ZoneFileStore!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EgressGraphTests-\(UUID().uuidString)", isDirectory: true)
        store = ZoneFileStore(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testGraphRoundTrip() throws {
        let f = Fixture()
        try store.saveGraph(f.graph, zoneID: f.zoneID)
        let loaded = try XCTUnwrap(store.loadGraph(f.zoneID))
        XCTAssertEqual(loaded.nodes.count, f.graph.nodes.count)
        XCTAssertEqual(loaded.edges.count, f.graph.edges.count)
        XCTAssertEqual(loaded.version, BuildingGraph.currentVersion)
    }

    func testCorruptGraphReturnsNilSoItCanBeRebuilt() throws {
        let zoneID = UUID()
        try store.saveZone(MappingZone(id: zoneID, campus: "C", building: "B", floor: "1", zoneName: "Z"))
        try Data("{ broken".utf8).write(to: store.url(zoneID, "graph.json"))
        XCTAssertNil(store.loadGraph(zoneID), "A corrupt graph must degrade to nil, not crash")
    }

    func testHazardsPersistSeparatelyFromGraph() throws {
        let f = Fixture()
        let edgeID = f.graph.edges[0].id
        try store.saveGraph(f.graph, zoneID: f.zoneID)

        var active = ActiveHazards(zoneID: f.zoneID)
        active.set(RouteHazard(type: .smoke), on: edgeID)
        try store.saveHazards(active, zoneID: f.zoneID)

        let reloadedGraph = try XCTUnwrap(store.loadGraph(f.zoneID))
        XCTAssertFalse(
            reloadedGraph.edges.contains { $0.hazard != nil },
            "Hazards must not be written into graph.json"
        )
        XCTAssertEqual(store.loadHazards(f.zoneID).hazards.count, 1)
    }

    func testClearingHazardsLeavesGraphIntact() throws {
        let f = Fixture()
        try store.saveGraph(f.graph, zoneID: f.zoneID)
        var active = ActiveHazards(zoneID: f.zoneID)
        active.set(RouteHazard(type: .fire), on: f.graph.edges[0].id)
        try store.saveHazards(active, zoneID: f.zoneID)

        try store.clearHazards(f.zoneID)

        XCTAssertTrue(store.loadHazards(f.zoneID).isEmpty)
        XCTAssertNotNil(store.loadGraph(f.zoneID))
    }

    func testMissingHazardFileReturnsEmpty() {
        XCTAssertTrue(store.loadHazards(UUID()).isEmpty)
    }

    func testClearingAbsentHazardsDoesNotThrow() {
        XCTAssertNoThrow(try store.clearHazards(UUID()))
    }

    func testProfileRoundTrip() throws {
        XCTAssertEqual(store.loadProfile(), .standard)
        try store.saveProfile(.wheelchair)
        let loaded = store.loadProfile()
        XCTAssertTrue(loaded.avoidStairs)
        XCTAssertTrue(loaded.requireWheelchairAccessible)
    }

    func testMigrationDoesNotDeleteSourceFiles() throws {
        let zoneID = UUID()
        let zone = MappingZone(id: zoneID, campus: "C", building: "B", floor: "1", zoneName: "Z")
        try store.saveZone(zone)

        let waypoints = [
            waypoint("Room 1", .room, x: 0, z: 0, index: 0, zoneID: zoneID),
            waypoint("Exit", .exit, x: 0, z: 10, index: 10, zoneID: zoneID),
        ]
        try store.saveWaypoints(waypoints, zoneID: zoneID)
        try store.savePath(RoutePath(), zoneID: zoneID)

        let repo = ZoneRepository(store: store)
        let graph = repo.graph(for: zone)

        XCTAssertNotNil(graph)
        XCTAssertEqual(store.loadWaypoints(zoneID).count, 2, "Source waypoints must survive migration")
        XCTAssertNotNil(store.loadGraph(zoneID), "Migrated graph should be persisted")
    }

    func testRoutePositionCodableRoundTrip() throws {
        let position = RoutePosition(
            edgeID: UUID(), nodeID: nil, fractionAlongEdge: 0.42,
            worldPosition: SIMD3<Float>(1, 2, 3)
        )
        let decoded = try JSONDecoder().decode(
            RoutePosition.self, from: JSONEncoder().encode(position)
        )
        XCTAssertEqual(decoded, position)
        XCTAssertEqual(decoded.fractionAlongEdge ?? 0, 0.42, accuracy: 1e-9)
    }
}
