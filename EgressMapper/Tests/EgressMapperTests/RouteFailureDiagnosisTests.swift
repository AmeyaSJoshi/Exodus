import XCTest
import simd
@testable import EgressMapper

/// Routing failures used to all report "Every path is blocked", regardless of
/// cause. That sent users looking for a closure that did not exist, and hid the
/// real problem: waypoints form one unbranched chain, so a single closure cuts
/// the building in two.
final class RouteFailureDiagnosisTests: XCTestCase {

    private let zoneID = UUID()

    private func at(_ x: Float) -> CodableTransform {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, 0, 0, 1)
        return CodableTransform(m)
    }

    private func node(_ name: String, _ type: RouteNodeType, _ x: Float) -> RouteNode {
        RouteNode(name: name, type: type, position: at(x), zoneID: zoneID)
    }

    private func from(_ node: RouteNode) -> RoutePosition {
        RoutePosition(nodeID: node.id, worldPosition: node.worldPosition)
    }

    // MARK: - The reported case

    /// Room — Exit A — Stairwell, with a second exit further along. Blocking a
    /// link in the chain strands whatever sits behind it.
    func testABlockedChainReportsTheBlockageNotAMapProblem() throws {
        let stairwell = node("Stairwell to Floor 1", .stairwell, 0)
        let exitA = node("Game Room Exit", .exit, 5)
        let room = node("Dada Bedroom", .room, 10)
        let exitB = node("Dada Exit", .exit, 15)

        var blockedEdge = RouteEdge(
            fromNodeID: stairwell.id, toNodeID: exitA.id, distanceMeters: 5
        )
        blockedEdge.isBlocked = true

        let graph = BuildingGraph(
            zoneID: zoneID,
            nodes: [stairwell, exitA, room, exitB],
            edges: [
                blockedEdge,
                RouteEdge(fromNodeID: exitA.id, toNodeID: room.id, distanceMeters: 5),
                RouteEdge(fromNodeID: room.id, toNodeID: exitB.id, distanceMeters: 5),
            ]
        )

        // Standing at the stairwell, behind the only closure: genuinely stuck.
        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(
                from: from(stairwell), graph: graph, profile: .standard
            )
        ) { error in
            guard case RoutingError.allRoutesBlocked = error else {
                return XCTFail("expected allRoutesBlocked, got \(error)")
            }
            let text = error.localizedDescription
            XCTAssertTrue(text.lowercased().contains("blocked"))
        }

        // Standing on the other side, exits are still reachable — one closure
        // must never rule out an exit that sits beyond it.
        let options = try ShortestPathService.findBestEgressRoute(
            from: from(room), graph: graph, profile: .standard
        )
        XCTAssertTrue(
            [exitA.id, exitB.id].contains(options.best.destination.id),
            "a closure elsewhere must not strand someone who has a way out"
        )
        XCTAssertTrue(options.unreachable.isEmpty)
    }

    /// The message that started this: shown after every closure was cleared.
    func testAnUnconnectedStartDoesNotClaimAnythingIsBlocked() {
        let stranded = node("Dada Bathroom", .room, 0)
        let room = node("Dada Bedroom", .room, 5)
        let exit = node("Dada Exit", .exit, 10)

        // `stranded` has no edge at all — nothing is blocked anywhere.
        let graph = BuildingGraph(
            zoneID: zoneID,
            nodes: [stranded, room, exit],
            edges: [RouteEdge(fromNodeID: room.id, toNodeID: exit.id, distanceMeters: 5)]
        )

        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(
                from: from(stranded), graph: graph, profile: .standard
            )
        ) { error in
            guard case RoutingError.startNotConnected(let name) = error else {
                return XCTFail("expected startNotConnected, got \(error)")
            }
            XCTAssertEqual(name, "Dada Bathroom")
            let text = error.localizedDescription
            XCTAssertTrue(
                text.contains("nothing is blocked"),
                "the user must not be told to look for a closure that does not exist"
            )
        }
    }

    func testAMapWithNoExitSaysSoRatherThanBlamingBlockages() {
        let a = node("Dada Bedroom", .room, 0)
        let b = node("Ameya Bedroom", .room, 5)
        let graph = BuildingGraph(
            zoneID: zoneID, nodes: [a, b],
            edges: [RouteEdge(fromNodeID: a.id, toNodeID: b.id, distanceMeters: 5)]
        )

        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(
                from: from(a), graph: graph, profile: .standard
            )
        ) { error in
            XCTAssertEqual(error as? RoutingError, .noExitsOnMap)
            XCTAssertTrue(error.localizedDescription.contains("no exit marked"))
        }
    }

    func testAnAccessibilityDeadEndIsNotReportedAsABlockage() {
        let room = node("Dada Bedroom", .room, 0)
        let stairs = node("Stairwell", .stairwell, 5)
        let exit = node("Game Room Exit", .exit, 10)

        let graph = BuildingGraph(
            zoneID: zoneID,
            nodes: [room, stairs, exit],
            edges: [
                RouteEdge(
                    fromNodeID: room.id, toNodeID: stairs.id, distanceMeters: 5,
                    accessibility: .between(.room, .stairwell)
                ),
                RouteEdge(
                    fromNodeID: stairs.id, toNodeID: exit.id, distanceMeters: 5,
                    accessibility: .between(.stairwell, .exit)
                ),
            ]
        )

        var profile = NavigationProfile.standard
        profile.avoidStairs = true

        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(
                from: from(room), graph: graph, profile: profile
            )
        ) { error in
            guard case RoutingError.noAccessibleRoute = error else {
                return XCTFail("expected noAccessibleRoute, got \(error)")
            }
        }
    }

    /// A closure must not change the diagnosis for someone who can still get
    /// out another way.
    func testAnUnaffectedUserStillRoutesWhileAClosureIsActive() throws {
        let room = node("Ameya Bedroom", .room, 0)
        let junction = node("Hallway", .intersection, 5)
        let exitA = node("Game Room Exit", .exit, 10)
        let exitB = node("Dada Exit", .exit, -5)

        var blocked = RouteEdge(fromNodeID: junction.id, toNodeID: exitA.id, distanceMeters: 5)
        blocked.isBlocked = true

        let graph = BuildingGraph(
            zoneID: zoneID,
            nodes: [room, junction, exitA, exitB],
            edges: [
                RouteEdge(fromNodeID: room.id, toNodeID: junction.id, distanceMeters: 5),
                blocked,
                RouteEdge(fromNodeID: room.id, toNodeID: exitB.id, distanceMeters: 5),
            ]
        )

        let options = try ShortestPathService.findBestEgressRoute(
            from: from(room), graph: graph, profile: .standard
        )
        XCTAssertEqual(options.best.destination.id, exitB.id)
        XCTAssertEqual(options.unreachable.map(\.node.id), [exitA.id])
    }

    /// Clearing the closure must restore the original route, with no residue
    /// from the failed attempt.
    func testClearingAClosureRestoresTheRoute() throws {
        let stairwell = node("Stairwell to Floor 1", .stairwell, 0)
        let exitA = node("Game Room Exit", .exit, 5)

        var blocked = RouteEdge(fromNodeID: stairwell.id, toNodeID: exitA.id, distanceMeters: 5)
        blocked.isBlocked = true
        let blockedGraph = BuildingGraph(
            zoneID: zoneID, nodes: [stairwell, exitA], edges: [blocked]
        )
        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(
                from: from(stairwell), graph: blockedGraph, profile: .standard
            )
        )

        // Same graph, closure lifted — exactly what a live `available` update
        // produces through LiveStateOverlay.effectiveGraph.
        let cleared = BuildingGraph(
            zoneID: zoneID, nodes: [stairwell, exitA],
            edges: [RouteEdge(fromNodeID: stairwell.id, toNodeID: exitA.id, distanceMeters: 5)]
        )
        let options = try ShortestPathService.findBestEgressRoute(
            from: from(stairwell), graph: cleared, profile: .standard
        )
        XCTAssertEqual(options.best.destination.id, exitA.id)
    }

    /// The live overlay is the thing that lifts a closure in the real app;
    /// prove the round trip rather than only the hand-built graphs above.
    func testOverlayClearProducesARoutableGraphAgain() throws {
        let buildingID = UUID()
        let stairwell = node("Stairwell to Floor 1", .stairwell, 0)
        let exit = node("Game Room Exit", .exit, 5)
        let edge = RouteEdge(fromNodeID: stairwell.id, toNodeID: exit.id, distanceMeters: 5)
        let permanent = BuildingGraph(zoneID: zoneID, nodes: [stairwell, exit], edges: [edge])

        var overlay = LiveStateOverlay(buildingID: buildingID)
        overlay.apply(edge: LiveEdgeState(
            edgeStableID: edge.id, status: .blocked, hazardType: nil,
            reason: "Blocked by administrator", severity: 5, revision: 1, expiresAt: nil
        ))
        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(
                from: from(stairwell),
                graph: overlay.effectiveGraph(from: permanent),
                profile: .standard
            )
        )

        overlay.apply(edge: LiveEdgeState(
            edgeStableID: edge.id, status: .available, hazardType: nil,
            reason: nil, severity: 1, revision: 2, expiresAt: nil
        ))
        let options = try ShortestPathService.findBestEgressRoute(
            from: from(stairwell),
            graph: overlay.effectiveGraph(from: permanent),
            profile: .standard
        )
        XCTAssertEqual(options.best.destination.id, exit.id)
    }
}
