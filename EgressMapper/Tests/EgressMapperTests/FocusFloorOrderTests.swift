import simd
import XCTest
@testable import EgressMapper

/// Floor order is what stacks the overlay: index N is drawn at N × 3m, so a
/// wrong order puts the tenth storey underneath the second.
final class FocusFloorOrderTests: XCTestCase {
    private func graph(floors: [String]) -> BuildingGraph {
        let zone = UUID()
        let nodes = floors.map { floorID in
            RouteNode(
                name: "N-\(floorID)",
                type: .room,
                position: CodableTransform(matrix_identity_float4x4),
                zoneID: zone,
                floorID: floorID
            )
        }
        return BuildingGraph(zoneID: zone, nodes: nodes, edges: [])
    }

    func testFloorsSortNumericallyNotLexically() {
        // The bug this guards: a plain string sort orders 1, 10, 2.
        let ordered = FocusOverlayBuilder.floors(in: graph(floors: ["floor-10", "floor-1", "floor-2"]))
        XCTAssertEqual(ordered, ["floor-1", "floor-2", "floor-10"])
    }

    func testFloorIndexFollowsNumericOrder() {
        let floors = FocusOverlayBuilder.floors(in: graph(floors: ["floor-10", "floor-1", "floor-2"]))
        XCTAssertEqual(FocusOverlayBuilder.floorIndex("floor-1", in: floors), 0)
        XCTAssertEqual(FocusOverlayBuilder.floorIndex("floor-2", in: floors), 1)
        XCTAssertEqual(FocusOverlayBuilder.floorIndex("floor-10", in: floors), 2)
    }

    func testBasementsSortBelowGround() {
        let ordered = FocusOverlayBuilder.floors(in: graph(floors: ["floor-2", "-1", "floor-1"]))
        XCTAssertEqual(ordered.first, "-1")
    }

    func testUnnumberedLabelsSortAfterNumberedOnes() {
        let ordered = FocusOverlayBuilder.floors(in: graph(floors: ["mezzanine", "floor-2", "floor-1"]))
        XCTAssertEqual(ordered, ["floor-1", "floor-2", "mezzanine"])
    }

    func testLevelExtraction() {
        XCTAssertEqual(FocusOverlayBuilder.level(of: "floor-10"), 10)
        XCTAssertEqual(FocusOverlayBuilder.level(of: "B2"), 2)
        XCTAssertEqual(FocusOverlayBuilder.level(of: "-1"), -1)
        XCTAssertNil(FocusOverlayBuilder.level(of: "mezzanine"))
    }
}
