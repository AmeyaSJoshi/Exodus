import XCTest
import simd
@testable import EgressMapper

final class CodableTransformTests: XCTestCase {
    func testRoundTripPreservesMatrix() throws {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(1.5, -2.25, 3.75, 1)
        m.columns.0 = SIMD4<Float>(0.5, 0.1, 0.2, 0)

        let encoded = try JSONEncoder().encode(CodableTransform(m))
        let decoded = try JSONDecoder().decode(CodableTransform.self, from: encoded)

        XCTAssertEqual(decoded.matrix.columns.3.x, m.columns.3.x, accuracy: 1e-6)
        XCTAssertEqual(decoded.matrix.columns.3.y, m.columns.3.y, accuracy: 1e-6)
        XCTAssertEqual(decoded.matrix.columns.3.z, m.columns.3.z, accuracy: 1e-6)
        XCTAssertEqual(decoded.matrix.columns.0.x, m.columns.0.x, accuracy: 1e-6)
        XCTAssertEqual(decoded.position, SIMD3<Float>(1.5, -2.25, 3.75))
    }

    func testMalformedArrayFallsBackToIdentity() {
        var t = CodableTransform(matrix_identity_float4x4)
        t.m = [1, 2, 3]
        XCTAssertEqual(t.matrix, matrix_identity_float4x4)
        XCTAssertEqual(t.position, .zero)
    }
}

final class MapPointTests: XCTestCase {
    func testProjectionDropsYAxis() {
        let p = MapPoint(projecting: SIMD3<Float>(3, 99, -4))
        XCTAssertEqual(p.x, 3, accuracy: 1e-6)
        XCTAssertEqual(p.y, -4, accuracy: 1e-6)
    }

    func testDistance() {
        XCTAssertEqual(MapPoint(x: 0, y: 0).distance(to: MapPoint(x: 3, y: 4)), 5, accuracy: 1e-9)
    }
}

final class RoutePathTests: XCTestCase {
    func testShouldRecordFirstPointAlways() {
        XCTAssertTrue(RoutePath.shouldRecord(
            newPosition: .zero, newHeading: 0,
            lastPosition: nil, lastHeading: nil, lastTime: nil, now: 0
        ))
    }

    func testShouldNotRecordTinyMovement() {
        XCTAssertFalse(RoutePath.shouldRecord(
            newPosition: SIMD3<Float>(0.05, 0, 0), newHeading: 0.01,
            lastPosition: .zero, lastHeading: 0, lastTime: 0, now: 0.2
        ))
    }

    func testRecordsAfterDistanceThreshold() {
        XCTAssertTrue(RoutePath.shouldRecord(
            newPosition: SIMD3<Float>(0.30, 0, 0), newHeading: 0,
            lastPosition: .zero, lastHeading: 0, lastTime: 0, now: 0.2
        ))
    }

    func testRecordsAfterRotationThreshold() {
        XCTAssertTrue(RoutePath.shouldRecord(
            newPosition: .zero, newHeading: 0.5,
            lastPosition: .zero, lastHeading: 0, lastTime: 0, now: 0.2
        ))
    }

    func testRotationWrapAroundIsNotAFalsePositive() {
        // 0.01 rad either side of ±π is a tiny turn, not a 2π one.
        XCTAssertFalse(RoutePath.shouldRecord(
            newPosition: .zero, newHeading: -.pi + 0.01,
            lastPosition: .zero, lastHeading: .pi - 0.01, lastTime: 0, now: 0.1
        ))
    }

    func testRecordsAfterMaxInterval() {
        XCTAssertTrue(RoutePath.shouldRecord(
            newPosition: .zero, newHeading: 0,
            lastPosition: .zero, lastHeading: 0, lastTime: 0, now: 5
        ))
    }

    func testTotalDistanceIgnoresVerticalBobbing() {
        var path = RoutePath()
        path.append(SIMD3<Float>(0, 1.4, 0), at: 0)
        path.append(SIMD3<Float>(3, 1.7, 0), at: 1)   // 3 m forward, 0.3 m up
        path.append(SIMD3<Float>(3, 1.2, 4), at: 2)   // 4 m sideways
        XCTAssertEqual(path.totalDistance, 7, accuracy: 1e-6)
    }

    func testSimplificationRemovesCollinearNoise() {
        var path = RoutePath()
        for i in 0...20 {
            path.append(SIMD3<Float>(Float(i) * 0.5, 0, 0), at: TimeInterval(i))
        }
        let simplified = path.simplified(epsilon: 0.15)
        XCTAssertEqual(simplified.count, 2, "A straight line should reduce to its endpoints")
    }

    func testSimplificationKeepsCorners() {
        var path = RoutePath()
        for i in 0...10 { path.append(SIMD3<Float>(Float(i), 0, 0), at: TimeInterval(i)) }
        for i in 1...10 { path.append(SIMD3<Float>(10, 0, Float(i)), at: TimeInterval(10 + i)) }
        let simplified = path.simplified(epsilon: 0.15)
        XCTAssertEqual(simplified.count, 3, "An L-shape should keep start, corner and end")
    }

    func testPerpendicularDistanceDegenerateSegment() {
        let d = RoutePath.perpendicularDistance(
            MapPoint(x: 3, y: 4), lineStart: MapPoint(x: 0, y: 0), lineEnd: MapPoint(x: 0, y: 0)
        )
        XCTAssertEqual(d, 5, accuracy: 1e-9)
    }
}

// MARK: - Fixtures

private func makeWaypoint(
    _ name: String,
    _ type: WaypointType,
    x: Float,
    z: Float,
    index: Int,
    zoneID: UUID = UUID()
) -> Waypoint {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(x, 1.4, z, 1)
    return Waypoint(
        zoneID: zoneID,
        name: name,
        type: type,
        anchorID: UUID(),
        transform: CodableTransform(m),
        pathIndex: index
    )
}

final class GuidanceEngineTests: XCTestCase {
    private func makeNode(_ name: String, _ type: RouteNodeType, x: Float, z: Float) -> RouteNode {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, 1.4, z, 1)
        return RouteNode(name: name, type: type, position: CodableTransform(m), zoneID: UUID())
    }

    private func straightRoute() -> [RouteNode] {
        [
            makeNode("Room 214", .room, x: 0, z: 0),
            makeNode("Intersection", .intersection, x: 0, z: 10),
            makeNode("Exit A", .exit, x: 10, z: 10),
        ]
    }

    func testAdvancesLegOnArrival() {
        var engine = GuidanceEngine(route: straightRoute())
        _ = engine.update(position: SIMD3<Float>(0, 1.4, 0))
        XCTAssertEqual(engine.legIndex, 0)

        let atIntersection = engine.update(position: SIMD3<Float>(0, 1.4, 10))
        XCTAssertEqual(engine.legIndex, 1)
        XCTAssertEqual(atIntersection.nextNode?.name, "Exit A")
    }

    func testArrivalAtDestination() {
        var engine = GuidanceEngine(route: straightRoute())
        _ = engine.update(position: SIMD3<Float>(0, 1.4, 10))
        let final = engine.update(position: SIMD3<Float>(10, 1.4, 10))
        XCTAssertTrue(final.arrived)
        XCTAssertTrue(final.instruction.contains("Exit A"))
    }

    func testDistanceToNextIsGroundPlane() {
        var engine = GuidanceEngine(route: straightRoute())
        let u = engine.update(position: SIMD3<Float>(0, 5, 4))  // 5 m of height
        XCTAssertEqual(u.distanceToNext, 6, accuracy: 0.001)
    }

    func testEmptyRouteIsSafe() {
        var engine = GuidanceEngine(route: [])
        let u = engine.update(position: .zero)
        XCTAssertFalse(u.arrived)
        XCTAssertNil(u.nextNode)
    }

    func testTurnDirections() {
        let a = MapPoint(x: 0, y: 0)
        let b = MapPoint(x: 0, y: 10)
        XCTAssertEqual(GuidanceEngine.turnDirection(from: a, via: b, to: MapPoint(x: 0, y: 20)), .straight)
        XCTAssertEqual(GuidanceEngine.turnDirection(from: a, via: b, to: MapPoint(x: 10, y: 10)), .left)
        XCTAssertEqual(GuidanceEngine.turnDirection(from: a, via: b, to: MapPoint(x: -10, y: 10)), .right)
        XCTAssertEqual(GuidanceEngine.turnDirection(from: a, via: b, to: MapPoint(x: 0, y: -5)), .around)
    }
}

final class ZoneFileStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var store: ZoneFileStore!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EgressTests-\(UUID().uuidString)", isDirectory: true)
        store = ZoneFileStore(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func sampleZone() -> MappingZone {
        MappingZone(campus: "Bellarmine", building: "Wade", floor: "Floor 2", zoneName: "East Hallway")
    }

    func testZoneRoundTrip() throws {
        let zone = sampleZone()
        try store.saveZone(zone)
        let loaded = store.loadZone(zone.id)
        XCTAssertEqual(loaded?.zoneName, "East Hallway")
        XCTAssertEqual(loaded?.building, "Wade")
        XCTAssertEqual(store.listZones().count, 1)
    }

    func testWaypointsAndPathRoundTrip() throws {
        let zone = sampleZone()
        try store.saveZone(zone)

        let waypoints = [
            makeWaypoint("Room 214", .room, x: 0, z: 0, index: 0, zoneID: zone.id),
            makeWaypoint("Exit A", .exit, x: 0, z: 12, index: 12, zoneID: zone.id),
        ]
        var path = RoutePath()
        path.append(SIMD3<Float>(0, 1.4, 0), at: 0)
        path.append(SIMD3<Float>(0, 1.4, 12), at: 1)

        try store.saveWaypoints(waypoints, zoneID: zone.id)
        try store.savePath(path, zoneID: zone.id)

        XCTAssertEqual(store.loadWaypoints(zone.id).count, 2)
        XCTAssertEqual(store.loadWaypoints(zone.id).first?.name, "Room 214")
        XCTAssertEqual(store.loadPath(zone.id).totalDistance, 12, accuracy: 0.001)
    }

    func testMissingFilesDegradeGracefully() {
        let unknown = UUID()
        XCTAssertNil(store.loadZone(unknown))
        XCTAssertTrue(store.loadWaypoints(unknown).isEmpty)
        XCTAssertTrue(store.loadPath(unknown).isEmpty)
        XCTAssertFalse(store.hasWorldMap(unknown))
    }

    func testCorruptedFilesDoNotCrashOrHideOtherZones() throws {
        let good = sampleZone()
        try store.saveZone(good)

        // A zone directory whose JSON is garbage.
        let bad = UUID()
        let badDir = tempRoot.appendingPathComponent(bad.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: badDir.appendingPathComponent("zone.json"))

        let zones = store.listZones()
        XCTAssertEqual(zones.count, 1, "A corrupt zone must not hide the healthy one")
        XCTAssertEqual(zones.first?.id, good.id)
    }

    func testCorruptWorldMapThrowsReadableError() throws {
        let zone = sampleZone()
        try store.saveZone(zone)
        try Data("not an ARWorldMap".utf8)
            .write(to: store.url(zone.id, "worldmap.arexperience"))

        XCTAssertThrowsError(try store.loadWorldMap(zone.id)) { error in
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription
                            ?? (error as NSError).localizedDescription)
        }
    }

    func testMissingWorldMapThrowsSpecificError() throws {
        let zone = sampleZone()
        try store.saveZone(zone)
        XCTAssertThrowsError(try store.loadWorldMap(zone.id)) { error in
            guard case ZoneStoreError.worldMapMissing = error else {
                return XCTFail("Expected .worldMapMissing, got \(error)")
            }
        }
    }

    func testDeleteRemovesZone() throws {
        let zone = sampleZone()
        try store.saveZone(zone)
        try store.deleteZone(zone.id)
        XCTAssertNil(store.loadZone(zone.id))
        XCTAssertTrue(store.listZones().isEmpty)
    }
}

final class TopDownProjectionTests: XCTestCase {
    func testFitTransformCentersAndPreservesAspect() {
        let bounds = TopDownRouteView.bounds(of: [
            MapPoint(x: 0, y: 0), MapPoint(x: 10, y: 0), MapPoint(x: 10, y: 5),
        ])
        XCTAssertEqual(bounds.width, 10, accuracy: 1e-9)
        XCTAssertEqual(bounds.height, 5, accuracy: 1e-9)

        let size = CGSize(width: 200, height: 200)
        let transform = TopDownRouteView.fitTransform(bounds: bounds, into: size, padding: 20)
        let a = transform(MapPoint(x: 0, y: 0))
        let b = transform(MapPoint(x: 10, y: 0))
        let c = transform(MapPoint(x: 10, y: 5))

        // Uniform scale: 10 map units wide maps to the same factor as 5 tall.
        let scaleX = (b.x - a.x) / 10
        let scaleY = (c.y - b.y) / 5
        XCTAssertEqual(scaleX, scaleY, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(b.x, size.width)
    }

    func testSinglePointDoesNotDivideByZero() {
        let bounds = TopDownRouteView.bounds(of: [MapPoint(x: 3, y: 3)])
        let transform = TopDownRouteView.fitTransform(bounds: bounds, into: CGSize(width: 100, height: 100), padding: 10)
        let p = transform(MapPoint(x: 3, y: 3))
        XCTAssertTrue(p.x.isFinite && p.y.isFinite)
    }
}

final class TrackingStatusTests: XCTestCase {
    func testNormalAndMappedAllowsSave() {
        let s = TrackingStatus.interpret(tracking: .normal, mapping: .mapped)
        XCTAssertTrue(s.canSave)
        XCTAssertTrue(s.isReliable)
        XCTAssertNil(s.saveBlockedReason)
    }

    func testLimitedTrackingBlocksSave() {
        let s = TrackingStatus.interpret(tracking: .limited(.insufficientFeatures), mapping: .mapped)
        XCTAssertFalse(s.canSave)
        XCTAssertFalse(s.isReliable)
        XCTAssertNotNil(s.saveBlockedReason)
        XCTAssertNotNil(s.advice)
    }

    func testNotAvailableMappingBlocksSave() {
        let s = TrackingStatus.interpret(tracking: .normal, mapping: .notAvailable)
        XCTAssertFalse(s.canSave)
        XCTAssertNotNil(s.saveBlockedReason)
    }

    func testRelocalizingIsFlagged() {
        let s = TrackingStatus.interpret(tracking: .limited(.relocalizing), mapping: .mapped)
        XCTAssertTrue(s.isRelocalizing)
        XCTAssertFalse(s.isReliable)
    }
}
