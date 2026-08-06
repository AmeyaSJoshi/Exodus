import XCTest
import simd
@testable import EgressMapper

/// Straight corridor: Room(0,0) — Intersection(0,10) — Exit(0,20)
private struct Corridor {
    let zoneID = UUID()
    let room: RouteNode
    let intersection: RouteNode
    let exit: RouteNode
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
        exit = makeNode("West Exit", .exit, x: 0, z: 20, zoneID: z)

        graph = BuildingGraph(
            zoneID: z,
            nodes: [room, intersection, exit],
            edges: [
                RouteEdge(fromNodeID: room.id, toNodeID: intersection.id, distanceMeters: 10),
                RouteEdge(fromNodeID: intersection.id, toNodeID: exit.id, distanceMeters: 10),
            ]
        )
    }

    var firstEdge: RouteEdge { graph.edges[0] }
    var secondEdge: RouteEdge { graph.edges[1] }
}

final class ProjectionTests: XCTestCase {

    func testPointOnSegmentProjectsExactly() {
        let r = LocalizationService.project(
            MapPoint(x: 0, y: 5), onto: MapPoint(x: 0, y: 0), MapPoint(x: 0, y: 10)
        )
        XCTAssertEqual(r.fraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.distance, 0, accuracy: 1e-9)
    }

    func testPerpendicularOffsetMeasuresDistance() {
        let r = LocalizationService.project(
            MapPoint(x: 3, y: 5), onto: MapPoint(x: 0, y: 0), MapPoint(x: 0, y: 10)
        )
        XCTAssertEqual(r.fraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.distance, 3, accuracy: 1e-9)
    }

    func testProjectionClampsBeforeSegmentStart() {
        let r = LocalizationService.project(
            MapPoint(x: 0, y: -8), onto: MapPoint(x: 0, y: 0), MapPoint(x: 0, y: 10)
        )
        XCTAssertEqual(r.fraction, 0, accuracy: 1e-9)
        XCTAssertEqual(r.distance, 8, accuracy: 1e-9)
    }

    func testProjectionClampsBeyondSegmentEnd() {
        let r = LocalizationService.project(
            MapPoint(x: 0, y: 25), onto: MapPoint(x: 0, y: 0), MapPoint(x: 0, y: 10)
        )
        XCTAssertEqual(r.fraction, 1, accuracy: 1e-9)
        XCTAssertEqual(r.distance, 15, accuracy: 1e-9)
    }

    func testDegenerateSegmentDoesNotDivideByZero() {
        let r = LocalizationService.project(
            MapPoint(x: 3, y: 4), onto: MapPoint(x: 0, y: 0), MapPoint(x: 0, y: 0)
        )
        XCTAssertEqual(r.distance, 5, accuracy: 1e-9)
        XCTAssertTrue(r.fraction.isFinite)
    }
}

final class LocationEstimateTests: XCTestCase {

    func testPointHalfwayAlongEdgeReturnsThatEdgeAndFraction() {
        let c = Corridor()
        let estimate = LocalizationService.estimate(
            worldPosition: SIMD3<Float>(0, 1.5, 5), graph: c.graph
        )
        XCTAssertEqual(estimate.routePosition.edgeID, c.firstEdge.id)
        XCTAssertEqual(estimate.routePosition.fractionAlongEdge ?? 0, 0.5, accuracy: 0.01)
        XCTAssertNil(estimate.routePosition.nodeID, "Mid-hallway must not snap to a node")
        XCTAssertEqual(estimate.confidence, .high)
    }

    func testPointDirectlyOnEdgeHasNearZeroDistance() {
        let c = Corridor()
        let estimate = LocalizationService.estimate(
            worldPosition: SIMD3<Float>(0, 1.5, 3), graph: c.graph
        )
        XCTAssertEqual(estimate.distanceFromRouteMeters, 0, accuracy: 1e-6)
        XCTAssertEqual(estimate.confidence, .high)
    }

    func testPointAtNodeReturnsTheNode() {
        let c = Corridor()
        let estimate = LocalizationService.estimate(
            worldPosition: SIMD3<Float>(0, 1.5, 10), graph: c.graph
        )
        XCTAssertEqual(estimate.routePosition.nodeID, c.intersection.id)
        XCTAssertNil(estimate.routePosition.edgeID)
        XCTAssertEqual(estimate.nearestNodeName, "Central Intersection")
    }

    func testCameraHeightIsIgnored() {
        let c = Corridor()
        let low = LocalizationService.estimate(worldPosition: SIMD3<Float>(0, 0.2, 5), graph: c.graph)
        let high = LocalizationService.estimate(worldPosition: SIMD3<Float>(0, 2.4, 5), graph: c.graph)
        XCTAssertEqual(low.distanceFromRouteMeters, high.distanceFromRouteMeters, accuracy: 1e-6)
        XCTAssertEqual(low.routePosition.edgeID, high.routePosition.edgeID)
    }

    func testConfidenceDegradesWithDistance() {
        let c = Corridor()
        let near = LocalizationService.estimate(worldPosition: SIMD3<Float>(1.0, 1.5, 5), graph: c.graph)
        let mid = LocalizationService.estimate(worldPosition: SIMD3<Float>(2.5, 1.5, 5), graph: c.graph)
        let far = LocalizationService.estimate(worldPosition: SIMD3<Float>(6.0, 1.5, 5), graph: c.graph)

        XCTAssertEqual(near.confidence, .high)
        XCTAssertEqual(mid.confidence, .medium)
        XCTAssertEqual(far.confidence, .low)
    }

    func testVeryFarFromRouteIsUnavailableNotLow() {
        let c = Corridor()
        let estimate = LocalizationService.estimate(
            worldPosition: SIMD3<Float>(500, 1.5, 500), graph: c.graph
        )
        XCTAssertEqual(estimate.confidence, .unavailable)
        XCTAssertNil(estimate.routePosition.edgeID, "Must not claim an edge when hopelessly far away")
        XCTAssertNil(estimate.routePosition.nodeID)
    }

    func testEmptyGraphIsUnavailable() {
        let empty = BuildingGraph(zoneID: UUID(), nodes: [], edges: [])
        let estimate = LocalizationService.estimate(worldPosition: .zero, graph: empty)
        XCTAssertEqual(estimate.confidence, .unavailable)
    }

    func testSingleNodeGraphSnapsToThatNode() {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(0, 1.4, 0, 1)
        let zoneID = UUID()
        let solo = RouteNode(name: "Room 1", type: .room, position: CodableTransform(m), zoneID: zoneID)
        let graph = BuildingGraph(zoneID: zoneID, nodes: [solo], edges: [])

        let estimate = LocalizationService.estimate(
            worldPosition: SIMD3<Float>(0.5, 1.5, 0), graph: graph
        )
        XCTAssertEqual(estimate.routePosition.nodeID, solo.id)
        XCTAssertEqual(estimate.confidence, .high)
    }

    func testPicksTheNearerOfTwoEdges() {
        let c = Corridor()
        // z = 16 sits on the second edge (10 -> 20).
        let estimate = LocalizationService.estimate(
            worldPosition: SIMD3<Float>(0, 1.5, 16), graph: c.graph
        )
        XCTAssertEqual(estimate.routePosition.edgeID, c.secondEdge.id)
    }

    func testLowConfidenceDoesNotAllowAutomaticNavigation() {
        XCTAssertFalse(LocationConfidence.low.allowsAutomaticNavigation)
        XCTAssertFalse(LocationConfidence.unavailable.allowsAutomaticNavigation)
        XCTAssertTrue(LocationConfidence.medium.allowsAutomaticNavigation)
        XCTAssertTrue(LocationConfidence.high.allowsAutomaticNavigation)
    }

    func testDescriptionMentionsZoneAndNearestNode() {
        let c = Corridor()
        let zone = MappingZone(campus: "Bellarmine", building: "Wade", floor: "Floor 2", zoneName: "East Hallway")
        let estimate = LocalizationService.estimate(
            worldPosition: SIMD3<Float>(0, 1.5, 1), graph: c.graph
        )
        let text = LocalizationService.describe(estimate, zone: zone)
        XCTAssertTrue(text.contains("East Hallway"))
        XCTAssertTrue(text.contains("Room 214"))
    }

    func testUnavailableEstimateDescribesHonestly() {
        let c = Corridor()
        let estimate = LocalizationService.estimate(
            worldPosition: SIMD3<Float>(900, 1.5, 900), graph: c.graph
        )
        let zone = MappingZone(campus: "C", building: "B", floor: "1", zoneName: "Z")
        XCTAssertTrue(LocalizationService.describe(estimate, zone: zone).contains("could not be determined"))
    }
}

/// The estimate must feed routing correctly — a mid-edge position should
/// produce a temporary start node, a node position should not.
final class LocalizationRoutingIntegrationTests: XCTestCase {

    func testMidEdgeEstimateRoutesViaTemporaryStart() throws {
        let c = Corridor()
        let estimate = LocalizationService.estimate(
            worldPosition: SIMD3<Float>(0, 1.5, 5), graph: c.graph
        )
        let route = try ShortestPathService.findRoute(
            from: estimate.routePosition, to: c.exit.id, graph: c.graph, profile: .standard
        )
        XCTAssertEqual(route.nodes.first?.type, .temporaryStart)
        XCTAssertEqual(route.destination.name, "West Exit")
        // 5 m to the intersection + 10 m to the exit.
        XCTAssertEqual(route.totalDistanceMeters, 15, accuracy: 0.01)
    }

    func testNodeEstimateRoutesDirectlyWithoutTemporaryNode() throws {
        let c = Corridor()
        let estimate = LocalizationService.estimate(
            worldPosition: SIMD3<Float>(0, 1.5, 10), graph: c.graph
        )
        let route = try ShortestPathService.findRoute(
            from: estimate.routePosition, to: c.exit.id, graph: c.graph, profile: .standard
        )
        XCTAssertEqual(route.nodes.first?.name, "Central Intersection")
        XCTAssertFalse(route.nodes.contains { $0.type == .temporaryStart })
    }

    func testUnavailableEstimateCannotStartRouting() {
        let c = Corridor()
        let estimate = LocalizationService.estimate(
            worldPosition: SIMD3<Float>(900, 1.5, 900), graph: c.graph
        )
        XCTAssertThrowsError(
            try ShortestPathService.findRoute(
                from: estimate.routePosition, to: c.exit.id, graph: c.graph, profile: .standard
            )
        ) { XCTAssertEqual($0 as? RoutingError, .unknownStart) }
    }

    func testLocalizationDoesNotMutateGraph() {
        let c = Corridor()
        let before = c.graph
        _ = LocalizationService.estimate(worldPosition: SIMD3<Float>(0, 1.5, 5), graph: c.graph)
        XCTAssertEqual(before, c.graph)
    }
}

final class MapTapInverseTests: XCTestCase {

    private var bounds: TopDownRouteView.Bounds {
        TopDownRouteView.bounds(of: [
            MapPoint(x: 0, y: 0), MapPoint(x: 20, y: 0), MapPoint(x: 20, y: 10),
        ])
    }

    func testInverseUndoesForwardTransform() {
        let size = CGSize(width: 300, height: 200)
        let forward = TopDownRouteView.fitTransform(bounds: bounds, into: size, padding: 24)
        let inverse = TopDownRouteView.inverseFitTransform(bounds: bounds, into: size, padding: 24)

        for original in [MapPoint(x: 3, y: 2), MapPoint(x: 17.5, y: 9), MapPoint(x: 0, y: 0)] {
            let back = inverse(forward(original))
            XCTAssertEqual(back.x, original.x, accuracy: 1e-6)
            XCTAssertEqual(back.y, original.y, accuracy: 1e-6)
        }
    }

    func testTapMapsIntoGraphSpaceAndSnaps() {
        let c = Corridor()
        let size = CGSize(width: 300, height: 300)
        let allPoints = c.graph.nodes.map(\.mapPoint)
        let b = TopDownRouteView.bounds(of: allPoints)
        let forward = TopDownRouteView.fitTransform(bounds: b, into: size, padding: 24)
        let inverse = TopDownRouteView.inverseFitTransform(bounds: b, into: size, padding: 24)

        // Tap exactly where the intersection is drawn.
        let tapped = inverse(forward(c.intersection.mapPoint))
        let world = SIMD3<Float>(Float(tapped.x), 0, Float(tapped.y))
        let estimate = LocalizationService.estimate(worldPosition: world, graph: c.graph)

        XCTAssertEqual(estimate.routePosition.nodeID, c.intersection.id)
    }

    func testDegenerateBoundsDoNotProduceNaN() {
        let single = TopDownRouteView.bounds(of: [MapPoint(x: 5, y: 5)])
        let inverse = TopDownRouteView.inverseFitTransform(
            bounds: single, into: CGSize(width: 100, height: 100), padding: 10
        )
        let p = inverse(CGPoint(x: 50, y: 50))
        XCTAssertTrue(p.x.isFinite && p.y.isFinite)
    }
}
