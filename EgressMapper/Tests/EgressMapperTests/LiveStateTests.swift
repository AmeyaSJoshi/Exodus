import XCTest
import simd
@testable import EgressMapper

/// Mirrors the seeded demo building:
///   Room ── Intersection ── Stairwell ── East Exit  (near, stairs)
///                        └─ Elevator  ── West Exit  (far, step-free)
private struct LiveFixture {
    let buildingID = UUID()
    let room, intersection, stairwell, eastExit, elevator, westExit: RouteNode
    let graph: BuildingGraph

    init() {
        func node(_ n: String, _ t: RouteNodeType, _ x: Float, _ z: Float, _ b: UUID) -> RouteNode {
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4<Float>(x, 1.4, z, 1)
            return RouteNode(name: n, type: t, position: CodableTransform(m), zoneID: b)
        }
        let b = buildingID
        room = node("Room 214", .room, 0, 0, b)
        intersection = node("Central Intersection", .intersection, 0, 10, b)
        stairwell = node("East Stairwell", .stairwell, 10, 10, b)
        eastExit = node("East Exit", .exit, 14, 10, b)
        elevator = node("Elevator", .elevator, -10, 10, b)
        westExit = node("West Exit", .exit, -40, 10, b)

        graph = BuildingGraph(
            zoneID: b,
            nodes: [room, intersection, stairwell, eastExit, elevator, westExit],
            edges: [
                RouteEdge(fromNodeID: room.id, toNodeID: intersection.id, distanceMeters: 10),
                RouteEdge(fromNodeID: intersection.id, toNodeID: stairwell.id, distanceMeters: 10,
                          accessibility: .between(.intersection, .stairwell)),
                RouteEdge(fromNodeID: stairwell.id, toNodeID: eastExit.id, distanceMeters: 4,
                          accessibility: .between(.stairwell, .exit)),
                RouteEdge(fromNodeID: intersection.id, toNodeID: elevator.id, distanceMeters: 10),
                RouteEdge(fromNodeID: elevator.id, toNodeID: westExit.id, distanceMeters: 30),
            ]
        )
    }

    var start: RoutePosition { RoutePosition(nodeID: room.id, worldPosition: room.worldPosition) }
    func edge(_ a: RouteNode, _ b: RouteNode) -> RouteEdge {
        graph.edges.first { $0.fromNodeID == a.id && $0.toNodeID == b.id }!
    }
    func route(_ graph: BuildingGraph, _ p: NavigationProfile = .standard) throws -> CalculatedRoute {
        try ShortestPathService.findBestEgressRoute(from: start, graph: graph, profile: p).best
    }
}

private func edgeState(
    _ id: UUID, _ status: LiveStatus, revision: Int64, expires: Date? = nil, severity: Int = 5
) -> LiveEdgeState {
    LiveEdgeState(edgeStableID: id, status: status, hazardType: "blockedHallway",
                  reason: "test", severity: severity, revision: revision, expiresAt: expires)
}

final class LiveOverlayTests: XCTestCase {

    func testOverlayNeverMutatesThePermanentGraph() throws {
        let f = LiveFixture()
        let stair = f.edge(f.intersection, f.stairwell)
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.apply(edge: edgeState(stair.id, .blocked, revision: 1))

        let effective = overlay.effectiveGraph(from: f.graph)

        XCTAssertTrue(effective.edges.contains { $0.id == stair.id && $0.isBlocked })
        XCTAssertFalse(
            f.graph.edges.contains { $0.isBlocked },
            "The permanent graph must never be changed by a live update"
        )
    }

    func testBlockedEdgeCausesRerouting() throws {
        let f = LiveFixture()
        XCTAssertEqual(try f.route(f.graph).destination.name, "East Exit")

        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.apply(edge: edgeState(f.edge(f.intersection, f.stairwell).id, .blocked, revision: 1))

        let rerouted = try f.route(overlay.effectiveGraph(from: f.graph))
        XCTAssertEqual(rerouted.destination.name, "West Exit")
    }

    func testUnaffectedUpdateLeavesTheRouteAlone() throws {
        let f = LiveFixture()
        let before = try f.route(f.graph)

        // Block a segment on the *other* branch, which the route does not use.
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.apply(edge: edgeState(f.edge(f.elevator, f.westExit).id, .blocked, revision: 1))

        XCTAssertFalse(overlay.routeIsAffected(before))
        let after = try f.route(overlay.effectiveGraph(from: f.graph))
        XCTAssertEqual(after.destination.id, before.destination.id)
    }

    func testRouteIsAffectedDetectsTheBlockedSegment() throws {
        let f = LiveFixture()
        let before = try f.route(f.graph)
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.apply(edge: edgeState(f.edge(f.intersection, f.stairwell).id, .blocked, revision: 1))
        XCTAssertTrue(overlay.routeIsAffected(before))
    }

    func testAccessibilityStillRespectedAfterALiveBlock() throws {
        let f = LiveFixture()
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.apply(edge: edgeState(f.edge(f.elevator, f.westExit).id, .blocked, revision: 1))

        // West is blocked; East needs stairs. A wheelchair user has nowhere to go.
        XCTAssertThrowsError(
            try f.route(overlay.effectiveGraph(from: f.graph), .wheelchair)
        ) { error in
            guard case RoutingError.noAccessibleRoute = error else {
                return XCTFail("Expected .noAccessibleRoute, got \(error)")
            }
        }
        // A standard user can still take the stairs.
        XCTAssertEqual(try f.route(overlay.effectiveGraph(from: f.graph)).destination.name, "East Exit")
    }

    func testClearingRestoresTheOriginalRoute() throws {
        let f = LiveFixture()
        let stair = f.edge(f.intersection, f.stairwell)
        var overlay = LiveStateOverlay(buildingID: f.buildingID)

        overlay.apply(edge: edgeState(stair.id, .blocked, revision: 1))
        XCTAssertEqual(try f.route(overlay.effectiveGraph(from: f.graph)).destination.name, "West Exit")

        overlay.apply(edge: edgeState(stair.id, .available, revision: 2))
        XCTAssertEqual(try f.route(overlay.effectiveGraph(from: f.graph)).destination.name, "East Exit")
    }

    func testBlockedNodeBlocksItsIncidentEdges() throws {
        let f = LiveFixture()
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.apply(node: LiveNodeState(
            nodeStableID: f.stairwell.id, status: .blocked, reason: nil,
            severity: 5, revision: 1, expiresAt: nil
        ))
        XCTAssertEqual(try f.route(overlay.effectiveGraph(from: f.graph)).destination.name, "West Exit")
    }

    func testRestrictedIsPenalisedButStillPassable() throws {
        let f = LiveFixture()
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.apply(edge: edgeState(f.edge(f.intersection, f.stairwell).id, .restricted, revision: 1))

        let effective = overlay.effectiveGraph(from: f.graph)
        let edge = effective.edges.first { $0.id == f.edge(f.intersection, f.stairwell).id }!
        XCTAssertFalse(edge.isBlocked, "restricted must not hard-block")
        XCTAssertGreaterThan(edge.hazardPenalty, 1)
        XCTAssertEqual(try f.route(effective).destination.name, "West Exit")
    }

    // MARK: - Personal reports

    func testPersonalBlockAffectsOnlyThisClient() throws {
        let f = LiveFixture()
        var mine = LiveStateOverlay(buildingID: f.buildingID)
        mine.addPersonalBlock(edgeID: f.edge(f.intersection, f.stairwell).id)

        XCTAssertEqual(try f.route(mine.effectiveGraph(from: f.graph)).destination.name, "West Exit")

        // Another phone, which received no server state, is unaffected.
        let theirs = LiveStateOverlay(buildingID: f.buildingID)
        XCTAssertEqual(try f.route(theirs.effectiveGraph(from: f.graph)).destination.name, "East Exit")
    }
}

final class LiveRevisionTests: XCTestCase {

    func testStaleRevisionIsIgnored() {
        let f = LiveFixture()
        let edge = f.edge(f.intersection, f.stairwell).id
        var overlay = LiveStateOverlay(buildingID: f.buildingID)

        XCTAssertTrue(overlay.apply(edge: edgeState(edge, .blocked, revision: 10)))
        // An out-of-order delivery of an older event must not un-block it.
        XCTAssertFalse(overlay.apply(edge: edgeState(edge, .available, revision: 4)))
        XCTAssertEqual(overlay.edgeStates[edge]?.status, .blocked)
        XCTAssertEqual(overlay.revision, 10)
    }

    func testEqualRevisionIsIgnored() {
        let f = LiveFixture()
        let edge = f.edge(f.intersection, f.stairwell).id
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.apply(edge: edgeState(edge, .blocked, revision: 7))
        XCTAssertFalse(overlay.apply(edge: edgeState(edge, .available, revision: 7)),
                       "Duplicate delivery must be a no-op")
        XCTAssertEqual(overlay.edgeStates[edge]?.status, .blocked)
    }

    func testNewerRevisionIsApplied() {
        let f = LiveFixture()
        let edge = f.edge(f.intersection, f.stairwell).id
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.apply(edge: edgeState(edge, .blocked, revision: 3))
        XCTAssertTrue(overlay.apply(edge: edgeState(edge, .available, revision: 9)))
        XCTAssertEqual(overlay.edgeStates[edge]?.status, .available)
        XCTAssertEqual(overlay.revision, 9)
    }

    func testApplyReportsWhetherTheStatusActuallyChanged() {
        let f = LiveFixture()
        let edge = f.edge(f.intersection, f.stairwell).id
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        XCTAssertTrue(overlay.apply(edge: edgeState(edge, .blocked, revision: 1)))
        // Same status, newer revision: applied, but nothing to react to.
        XCTAssertFalse(overlay.apply(edge: edgeState(edge, .blocked, revision: 2)))
        XCTAssertEqual(overlay.revision, 2)
    }

    func testSnapshotReplacementWinsAfterReconnect() {
        let f = LiveFixture()
        let stair = f.edge(f.intersection, f.stairwell).id
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.apply(edge: edgeState(stair, .blocked, revision: 5))

        // While offline the administrator cleared it; the snapshot is authoritative.
        overlay.replace(with: BuildingStateSnapshot(
            buildingID: f.buildingID, revision: 12,
            edges: [edgeState(stair, .available, revision: 12)], nodes: []
        ))
        XCTAssertEqual(overlay.edgeStates[stair]?.status, .available)
        XCTAssertEqual(overlay.revision, 12)
    }

    func testSnapshotForAnotherBuildingIsIgnored() {
        let f = LiveFixture()
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.replace(with: BuildingStateSnapshot(
            buildingID: UUID(), revision: 99,
            edges: [edgeState(UUID(), .blocked, revision: 99)], nodes: []
        ))
        XCTAssertEqual(overlay.revision, 0)
        XCTAssertTrue(overlay.edgeStates.isEmpty)
    }

    func testExpiredStateIsTreatedAsCleared() throws {
        let f = LiveFixture()
        let stair = f.edge(f.intersection, f.stairwell).id
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.apply(edge: edgeState(stair, .blocked, revision: 1,
                                      expires: Date().addingTimeInterval(-60)))

        XCTAssertTrue(overlay.blockedEdgeIDs().isEmpty)
        XCTAssertEqual(try f.route(overlay.effectiveGraph(from: f.graph)).destination.name, "East Exit")
    }

    func testUnexpiredStateStillApplies() throws {
        let f = LiveFixture()
        let stair = f.edge(f.intersection, f.stairwell).id
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.apply(edge: edgeState(stair, .blocked, revision: 1,
                                      expires: Date().addingTimeInterval(600)))
        XCTAssertEqual(try f.route(overlay.effectiveGraph(from: f.graph)).destination.name, "West Exit")
    }
}

final class RemoteGraphMapperTests: XCTestCase {

    func testStableIDsBecomeDomainIDs() {
        let nodeA = UUID(), nodeB = UUID(), edgeID = UUID(), building = UUID()
        let graph = RemoteGraphMapper.graph(
            buildingID: building,
            nodes: [
                .init(stableID: nodeA, floorID: "f2", name: "Room 214", type: "room",
                      position: .init(x: 0, y: 1.4, z: 0)),
                .init(stableID: nodeB, floorID: "f2", name: "East Exit", type: "exit",
                      position: .init(x: 0, y: 1.4, z: 10)),
            ],
            edges: [
                .init(stableID: edgeID, fromNodeStableID: nodeA, toNodeStableID: nodeB,
                      distanceMeters: 10, bidirectional: true, containsStairs: true,
                      requiresElevator: false, wheelchairAccessible: false),
            ]
        )
        XCTAssertEqual(graph.node(nodeA)?.name, "Room 214")
        XCTAssertEqual(graph.edge(edgeID)?.distanceMeters, 10)
        XCTAssertTrue(graph.edge(edgeID)!.accessibility.containsStairs)
        XCTAssertFalse(graph.edge(edgeID)!.accessibility.wheelchairAccessible)
        XCTAssertEqual(graph.exits.first?.name, "East Exit")
        XCTAssertEqual(graph.node(nodeA)?.worldPosition.z, 0)
    }

    func testEdgesWithMissingEndpointsAreDropped() {
        let nodeA = UUID()
        let graph = RemoteGraphMapper.graph(
            buildingID: UUID(),
            nodes: [.init(stableID: nodeA, floorID: "f", name: "A", type: "room",
                          position: .init(x: 0, y: 0, z: 0))],
            edges: [.init(stableID: UUID(), fromNodeStableID: nodeA, toNodeStableID: UUID(),
                          distanceMeters: 5, bidirectional: true, containsStairs: false,
                          requiresElevator: false, wheelchairAccessible: true)]
        )
        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertTrue(graph.edges.isEmpty, "An edge into nowhere must not reach the router")
    }

    func testUnknownNodeTypeFallsBackToHallwayPoint() {
        let id = UUID()
        let graph = RemoteGraphMapper.graph(
            buildingID: UUID(),
            nodes: [.init(stableID: id, floorID: "f", name: "Odd", type: "somethingNew",
                          position: .init(x: 1, y: 2, z: 3))],
            edges: []
        )
        XCTAssertEqual(graph.node(id)?.type, .hallwayPoint)
    }
}

final class LiveStateCacheTests: XCTestCase {
    private var root: URL!
    private var cache: LiveStateCache!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveCache-\(UUID().uuidString)", isDirectory: true)
        cache = LiveStateCache(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSnapshotRoundTrip() {
        let f = LiveFixture()
        let snapshot = BuildingStateSnapshot(
            buildingID: f.buildingID, revision: 42,
            edges: [edgeState(f.graph.edges[0].id, .blocked, revision: 42)], nodes: []
        )
        cache.saveSnapshot(snapshot, buildingID: f.buildingID)

        let loaded = LiveStateCache(root: root).loadSnapshot(buildingID: f.buildingID)
        XCTAssertEqual(loaded?.revision, 42)
        XCTAssertEqual(loaded?.edges.first?.status, .blocked)
    }

    func testGraphRoundTrip() {
        let f = LiveFixture()
        cache.saveGraph(f.graph, buildingID: f.buildingID)
        let loaded = LiveStateCache(root: root).loadGraph(buildingID: f.buildingID)
        XCTAssertEqual(loaded?.nodes.count, f.graph.nodes.count)
        XCTAssertEqual(loaded?.edges.count, f.graph.edges.count)
    }

    func testMissingCacheReturnsNil() {
        XCTAssertNil(cache.loadSnapshot(buildingID: UUID()))
        XCTAssertNil(cache.loadGraph(buildingID: UUID()))
    }

    func testCorruptCacheDegradesToNilRatherThanThrowing() throws {
        let id = UUID()
        try Data("{ broken".utf8).write(to: root.appendingPathComponent("\(id.uuidString)-state.json"))
        XCTAssertNil(cache.loadSnapshot(buildingID: id),
                     "A corrupt cache must not stop the app from starting")
    }

    func testOfflineRouteUsesCachedStateAndStillReroutes() throws {
        let f = LiveFixture()
        let stair = f.edge(f.intersection, f.stairwell).id
        cache.saveGraph(f.graph, buildingID: f.buildingID)
        cache.saveSnapshot(BuildingStateSnapshot(
            buildingID: f.buildingID, revision: 8,
            edges: [edgeState(stair, .blocked, revision: 8)], nodes: []
        ), buildingID: f.buildingID)

        // Cold start with no network at all.
        let graph = try XCTUnwrap(cache.loadGraph(buildingID: f.buildingID))
        var overlay = LiveStateOverlay(buildingID: f.buildingID)
        overlay.replace(with: try XCTUnwrap(cache.loadSnapshot(buildingID: f.buildingID)))

        let route = try ShortestPathService.findBestEgressRoute(
            from: f.start, graph: overlay.effectiveGraph(from: graph), profile: .standard
        ).best
        XCTAssertEqual(route.destination.name, "West Exit",
                       "Cached hazards must survive a restart with no network")
    }
}

final class LiveMessageTests: XCTestCase {
    func testBlockMessageNamesTheSegmentAndTheNewExit() {
        let message = LiveStateOverlay.changeMessage(
            edgeName: "East Stairwell", status: .blocked, newExit: "West Exit"
        )
        XCTAssertTrue(message.contains("East Stairwell"))
        XCTAssertTrue(message.contains("West Exit"))
        XCTAssertTrue(message.lowercased().contains("rerouting"))
    }

    func testClearMessageReadsAsRestoration() {
        let message = LiveStateOverlay.changeMessage(
            edgeName: "East Stairwell", status: .available, newExit: nil
        )
        XCTAssertTrue(message.contains("open again"))
    }
}
