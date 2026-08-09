import simd
import XCTest
@testable import EgressMapper

/// The style layers bind paint properties straight to feature properties, so a
/// missing or mistyped one is not a wrong pixel — it is an uncatchable
/// NSException out of MapLibre. These assertions are the contract.
final class FocusOverlayContractTests: XCTestCase {
    private let anchor = BuildingAnchor(
        latitude: 37.3428, longitude: -121.9181, altitudeM: 0, headingDeg: 0, scale: 1
    )

    /// Two floors, enough nodes per floor for a hull, and an edge to ribbon.
    private func graph() -> BuildingGraph {
        let zone = UUID()
        var nodes: [RouteNode] = []
        for (floor, base) in [("floor-1", 0), ("floor-2", 10)] {
            for (i, type) in [RouteNodeType.room, .intersection, .exit, .hallwayPoint].enumerated() {
                var m = matrix_identity_float4x4
                m.columns.3 = SIMD4<Float>(Float(base + i * 3), 0, Float(i * 4), 1)
                nodes.append(
                    RouteNode(
                        name: "\(type.rawValue)-\(floor)",
                        type: type,
                        position: CodableTransform(m),
                        zoneID: zone,
                        floorID: floor
                    )
                )
            }
        }
        let edge = RouteEdge(
            id: UUID(),
            fromNodeID: nodes[0].id,
            toNodeID: nodes[2].id,
            distanceMeters: 12,
            isBidirectional: true,
            isBlocked: false,
            accessibility: EdgeAccessibility(
                containsStairs: false, requiresElevator: false, wheelchairAccessible: true
            )
        )
        return BuildingGraph(zoneID: zone, nodes: nodes, edges: [edge])
    }

    private func properties(_ feature: [String: Any]) -> [String: Any] {
        feature["properties"] as? [String: Any] ?? [:]
    }

    /// Every extruded layer binds fill-extrusion base and height to these.
    private func assertExtrusionContract(_ features: [[String: Any]], _ label: String) {
        XCTAssertFalse(features.isEmpty, "\(label) produced no features")
        for feature in features {
            let p = properties(feature)
            XCTAssertNotNil(p["floorIdx"] as? Int, "\(label): floorIdx missing or not Int")
            XCTAssertNotNil(p["base"] as? Double, "\(label): base missing or not Double")
            XCTAssertNotNil(p["top"] as? Double, "\(label): top missing or not Double")
            if let base = p["base"] as? Double, let top = p["top"] as? Double {
                XCTAssertGreaterThan(top, base, "\(label): extrusion must have positive height")
            }
            XCTAssertEqual(feature["type"] as? String, "Feature")
        }
    }

    func testSlabsCarryTheExtrusionContract() {
        let g = graph()
        assertExtrusionContract(
            FocusOverlayBuilder.slabs(graph: g, anchor: anchor, floors: FocusOverlayBuilder.floors(in: g)),
            "slabs"
        )
    }

    func testRoomsCarryTheExtrusionContract() {
        let g = graph()
        assertExtrusionContract(
            FocusOverlayBuilder.rooms(graph: g, anchor: anchor, floors: FocusOverlayBuilder.floors(in: g)),
            "rooms"
        )
    }

    func testRoutesCarryTheExtrusionContractAndStepFreeFlag() {
        let g = graph()
        let routes = FocusOverlayBuilder.routes(graph: g, anchor: anchor, floors: FocusOverlayBuilder.floors(in: g))
        assertExtrusionContract(routes, "routes")
        for feature in routes {
            XCTAssertNotNil(properties(feature)["stepFree"] as? Bool, "routes: stepFree missing or not Bool")
        }
    }

    func testLabelsCarryTextAndExitFlag() {
        let g = graph()
        let labels = FocusOverlayBuilder.labels(graph: g, anchor: anchor, floors: FocusOverlayBuilder.floors(in: g))
        XCTAssertFalse(labels.isEmpty)
        for feature in labels {
            let p = properties(feature)
            XCTAssertNotNil(p["floorIdx"] as? Int, "labels: floorIdx missing or not Int")
            XCTAssertNotNil(p["isExit"] as? Bool, "labels: isExit missing or not Bool")
            let text = p["label"] as? String
            XCTAssertNotNil(text, "labels: label missing or not String")
            XCTAssertFalse(text?.isEmpty ?? true, "labels: label must not be empty")
        }
        // Hallway points are structure, not landmarks — labelling them buries
        // the exits, which is the whole point of the layer.
        XCTAssertFalse(labels.contains { ($0["properties"] as? [String: Any])?["name"] as? String == "hallwayPoint-floor-1" })
    }

    /// Floors stack at 3m, so the second floor's geometry must sit above the
    /// first — the altitude is what makes this a 3D view rather than a pile.
    func testFloorsStackAtDistinctHeights() {
        let g = graph()
        let floors = FocusOverlayBuilder.floors(in: g)
        let bases = FocusOverlayBuilder.slabs(graph: g, anchor: anchor, floors: floors)
            .compactMap { ($0["properties"] as? [String: Any])?["base"] as? Double }
            .sorted()
        XCTAssertEqual(bases, [0, FocusOverlayBuilder.floorHeightM])
    }

    /// The collection has to survive JSONSerialization or MLNShape gets nothing.
    func testFeatureCollectionSerialises() throws {
        let g = graph()
        let floors = FocusOverlayBuilder.floors(in: g)
        let data = try XCTUnwrap(
            FocusOverlayBuilder.collectionData(
                FocusOverlayBuilder.rooms(graph: g, anchor: anchor, floors: floors)
            )
        )
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(parsed?["type"] as? String, "FeatureCollection")
        XCTAssertNotNil(parsed?["features"] as? [[String: Any]])
    }
}
