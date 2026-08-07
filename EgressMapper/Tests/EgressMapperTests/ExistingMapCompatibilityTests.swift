import XCTest
import simd
@testable import EgressMapper

/// Maps recorded before packages existed must keep loading, unchanged, and must
/// still be publishable. These tests write the *old* on-disk shape by hand
/// rather than through today's writers, so a future change to the format
/// cannot quietly make them pass.
final class ExistingMapCompatibilityTests: XCTestCase {

    private var root: URL!
    private var store: ZoneFileStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("egress-legacy-\(UUID().uuidString)")
        store = ZoneFileStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// zone.json as written before `remoteBuildingID` and reference views were
    /// added: no such keys at all.
    private func writeLegacyZone(id: UUID) throws {
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {
          "id" : "\(id.uuidString)",
          "campus" : "Main Campus",
          "building" : "Wade",
          "floor" : "2",
          "zoneName" : "East Wing",
          "createdAt" : "2026-01-04T10:00:00Z",
          "updatedAt" : "2026-01-04T10:30:00Z",
          "waypointCount" : 3,
          "pathLength" : 24.5,
          "hasWorldMap" : true,
          "hasFloorPlan" : false,
          "hasReferenceImage" : true
        }
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("zone.json"))
    }

    func testAZoneSavedBeforePackagesStillDecodes() throws {
        let id = UUID()
        try writeLegacyZone(id: id)

        let zone = try XCTUnwrap(store.loadZone(id))
        XCTAssertEqual(zone.zoneName, "East Wing")
        XCTAssertEqual(zone.building, "Wade")
        XCTAssertEqual(zone.waypointCount, 3)
        XCTAssertNil(zone.remoteBuildingID, "an unpublished legacy zone has no building yet")
        XCTAssertEqual(store.listZones().count, 1)
    }

    func testALegacyReferenceImageIsOfferedAsAViewpoint() throws {
        let id = UUID()
        try writeLegacyZone(id: id)
        // The old single reference file, with no references.json beside it.
        try Data("legacy-jpeg".utf8).write(
            to: root.appendingPathComponent(id.uuidString).appendingPathComponent("reference.jpg")
        )

        let views = store.referenceViews(id)
        XCTAssertEqual(views.count, 1)
        XCTAssertEqual(views[0].fileName, "reference.jpg")
        XCTAssertEqual(
            store.referenceViewData(views[0], zoneID: id), Data("legacy-jpeg".utf8),
            "the original file is read in place, not rewritten"
        )
    }

    func testAddingViewpointsLeavesTheOriginalReferenceIntact() throws {
        let id = UUID()
        try writeLegacyZone(id: id)
        let original = root.appendingPathComponent(id.uuidString)
            .appendingPathComponent("reference.jpg")
        try Data("legacy-jpeg".utf8).write(to: original)

        let image = UIImage(systemName: "camera") ?? UIImage()
        try store.addReferenceView(image, viewpoint: "toward the lobby", zoneID: id)

        XCTAssertEqual(
            try Data(contentsOf: original), Data("legacy-jpeg".utf8),
            "the pre-existing reference image must never be overwritten"
        )
        let views = store.referenceViews(id)
        XCTAssertEqual(views.count, 2)
        XCTAssertTrue(views.contains { $0.viewpoint == "toward the lobby" })
    }

    func testALegacyZoneWithNoWorldMapStillPublishesItsGraph() throws {
        let id = UUID()
        try writeLegacyZone(id: id)
        let zone = try XCTUnwrap(store.loadZone(id))

        // No worldmap.arexperience, no references.json — nothing to upload.
        let artifacts = MapPublisher.artifacts(for: zone, store: store)
        XCTAssertTrue(artifacts.isEmpty)

        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        let room = RouteNode(name: "Room 214", type: .room, position: CodableTransform(m), zoneID: id)
        m.columns.3 = SIMD4<Float>(8, 0, 0, 1)
        let exit = RouteNode(name: "East Exit", type: .exit, position: CodableTransform(m), zoneID: id)
        let graph = BuildingGraph(
            zoneID: id, nodes: [room, exit],
            edges: [RouteEdge(fromNodeID: room.id, toNodeID: exit.id, distanceMeters: 8)]
        )

        let manifest = try MapPackageBuilder.build(
            zone: zone, graph: graph, buildingID: UUID(), buildingName: "Wade",
            mapVersionID: UUID(), version: 1, artifacts: artifacts
        )
        XCTAssertTrue(manifest.artifacts.isEmpty)
        XCTAssertFalse(
            manifest.zones[0].hasWorldMap,
            "publishable, but it must not claim an AR map it does not have"
        )
        XCTAssertTrue(
            BuildingLocalizationService.relocalizableZones(in: manifest).isEmpty,
            "so camera relocalization is correctly never offered for it"
        )
        // The route still works, which is the part that matters.
        let route = try ShortestPathService.findBestEgressRoute(
            from: RoutePosition(nodeID: room.id, worldPosition: room.worldPosition),
            graph: MapPackageBuilder.graph(from: manifest), profile: .standard
        )
        XCTAssertEqual(route.best.destination.name, "East Exit")
    }

    func testAWorldMapFileIsPickedUpForPublicationWithoutBeingRewritten() throws {
        let id = UUID()
        try writeLegacyZone(id: id)
        let mapURL = root.appendingPathComponent(id.uuidString)
            .appendingPathComponent("worldmap.arexperience")
        try Data("archived-arworldmap".utf8).write(to: mapURL)
        let zone = try XCTUnwrap(store.loadZone(id))

        let artifacts = MapPublisher.artifacts(for: zone, store: store)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts[0].kind, .worldmap)
        XCTAssertEqual(artifacts[0].data, Data("archived-arworldmap".utf8))
        XCTAssertEqual(
            try Data(contentsOf: mapURL), Data("archived-arworldmap".utf8),
            "publishing reads the saved map; it never modifies it"
        )
    }

    func testALegacyZoneSurvivesARoundTripThroughTodaysWriter() throws {
        let id = UUID()
        try writeLegacyZone(id: id)
        var zone = try XCTUnwrap(store.loadZone(id))

        zone.remoteBuildingID = UUID()
        try store.saveZone(zone)

        let reloaded = try XCTUnwrap(store.loadZone(id))
        XCTAssertEqual(reloaded.remoteBuildingID, zone.remoteBuildingID)
        XCTAssertEqual(reloaded.campus, "Main Campus")
        XCTAssertEqual(reloaded.pathLength, 24.5, accuracy: 0.001)
    }
}
