import XCTest
import simd
@testable import EgressMapper

/// A downloaded building keeps its ARWorldMap in the package cache, not under
/// `Zones/<id>/`. Emergency looked only in the local zone store, so a building
/// whose world map was present the whole time reported "This zone has no saved
/// world map" — and that stopped the evacuation instead of falling back to 2D.
final class WorldMapAvailabilityTests: XCTestCase {

    private var root: URL!
    private var cache: MapPackageCache!
    private var originalDecoder: ((Data) -> Bool)!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("egress-worldmap-\(UUID().uuidString)")
        cache = MapPackageCache(root: root)
        originalDecoder = ZoneFileStore.worldMapDecodes
        ZoneFileStore.worldMapDecodes = { !$0.isEmpty }
    }

    override func tearDownWithError() throws {
        ZoneFileStore.worldMapDecodes = originalDecoder
        try? FileManager.default.removeItem(at: root)
    }

    private func at(_ x: Float) -> CodableTransform {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, 0, 0, 1)
        return CodableTransform(m)
    }

    private let worldMapBytes = Data(repeating: 0xAB, count: 4096)

    /// Builds a package with or without a world map, and stores it as if it
    /// had just been downloaded.
    @discardableResult
    private func storePackage(
        buildingID: UUID, withWorldMap: Bool, version: Int = 1
    ) throws -> MapPackageManifest {
        let zone = MappingZone(campus: "M", building: "Wade", floor: "2", zoneName: "East Wing")
        let room = RouteNode(name: "Room 214", type: .room, position: at(0), zoneID: zone.id)
        let exit = RouteNode(name: "East Exit", type: .exit, position: at(10), zoneID: zone.id)
        let graph = BuildingGraph(
            zoneID: zone.id, nodes: [room, exit],
            edges: [RouteEdge(fromNodeID: room.id, toNodeID: exit.id, distanceMeters: 10)]
        )

        var pending: [PendingArtifact] = []
        if withWorldMap {
            pending.append(PendingArtifact(
                kind: .worldmap, zoneID: zone.id,
                fileName: "worldmap.arexperience", data: worldMapBytes
            ))
        }
        let manifest = try MapPackageBuilder.build(
            zone: zone, graph: graph, buildingID: buildingID, buildingName: "Wade",
            mapVersionID: UUID(), version: version, artifacts: pending
        )
        var files: [String: Data] = [:]
        for item in pending { files[manifest.artifact(item.id)!.storagePath] = item.data }
        try cache.store(manifest: manifest, files: files)
        return manifest
    }

    // MARK: - Locating the world map

    /// The regression itself.
    func testADownloadedWorldMapIsFoundInThePackageCache() throws {
        let buildingID = UUID()
        try storePackage(buildingID: buildingID, withWorldMap: true)

        let data = cache.worldMapData(buildingID: buildingID)
        XCTAssertEqual(
            data, worldMapBytes,
            "the world map lives in the package cache; looking only in the zone store found nothing"
        )
        XCTAssertTrue(cache.hasUsableWorldMap(buildingID: buildingID))
    }

    func testAGraphOnlyPackageReportsNoWorldMapRatherThanFailing() throws {
        let buildingID = UUID()
        let manifest = try storePackage(buildingID: buildingID, withWorldMap: false)

        XCTAssertNil(cache.worldMapData(buildingID: buildingID))
        XCTAssertFalse(cache.hasUsableWorldMap(buildingID: buildingID))
        // The package is still perfectly usable for routing.
        XCTAssertFalse(manifest.nodes.isEmpty)
        XCTAssertNotNil(cache.manifest(buildingID: buildingID))
    }

    func testAnUncachedBuildingHasNoWorldMapAndDoesNotCrash() {
        XCTAssertNil(cache.worldMapData(buildingID: UUID()))
        XCTAssertFalse(cache.hasUsableWorldMap(buildingID: UUID()))
    }

    /// A world map that fails its checksum must be treated as absent, not
    /// handed to ARKit.
    func testACorruptWorldMapIsReportedMissingRatherThanReturned() throws {
        let buildingID = UUID()
        let manifest = try storePackage(buildingID: buildingID, withWorldMap: true)
        let artifact = manifest.artifacts.first { $0.kind == .worldmap }!
        let onDisk = cache.fileURL(
            buildingID: buildingID, version: manifest.version, fileName: artifact.localFileName
        )
        try Data(repeating: 0x00, count: worldMapBytes.count).write(to: onDisk)

        XCTAssertNil(
            cache.worldMapData(buildingID: buildingID),
            "a checksum failure must not silently hand corrupt bytes to ARKit"
        )
        XCTAssertFalse(cache.hasUsableWorldMap(buildingID: buildingID))
        // And routing is unaffected — the graph is in the manifest.
        XCTAssertNotNil(cache.manifest(buildingID: buildingID))
    }

    func testTheWorldMapSurvivesAFreshCacheInstance() throws {
        let buildingID = UUID()
        try storePackage(buildingID: buildingID, withWorldMap: true)

        // A new cache over the same root is what an app relaunch amounts to.
        let reopened = MapPackageCache(root: root)
        XCTAssertEqual(reopened.worldMapData(buildingID: buildingID), worldMapBytes)
        XCTAssertTrue(reopened.hasUsableWorldMap(buildingID: buildingID))
    }

    func testAnUpdateReplacesTheWorldMapAndKeepsItReadable() throws {
        let buildingID = UUID()
        try storePackage(buildingID: buildingID, withWorldMap: true, version: 1)
        try storePackage(buildingID: buildingID, withWorldMap: true, version: 2)

        XCTAssertEqual(cache.cachedVersion(buildingID: buildingID), 2)
        XCTAssertEqual(cache.worldMapData(buildingID: buildingID), worldMapBytes)
    }

    // MARK: - Evacuation must not depend on AR

    /// The requirement: a graph-only map still evacuates, in 2D.
    func testAGraphOnlyPackageStillProducesAnEvacuationRoute() throws {
        let buildingID = UUID()
        try storePackage(buildingID: buildingID, withWorldMap: false)

        let manifest = try XCTUnwrap(cache.manifest(buildingID: buildingID))
        let graph = MapPackageBuilder.graph(from: manifest)
        let room = try XCTUnwrap(graph.nodes.first { $0.type == .room })

        let options = try ShortestPathService.findBestEgressRoute(
            from: RoutePosition(nodeID: room.id, worldPosition: room.worldPosition),
            graph: graph, profile: .standard
        )
        XCTAssertEqual(options.best.destination.name, "East Exit")
        XCTAssertFalse(
            cache.hasUsableWorldMap(buildingID: buildingID),
            "no AR map, yet the route is fine — AR must gate only AR"
        )
    }

    /// Manual room selection must reach a startable state whether or not a
    /// world map exists. Both branches produce a route from the same service.
    func testManualSelectionStartsRegardlessOfWorldMapPresence() throws {
        for hasMap in [true, false] {
            let buildingID = UUID()
            try storePackage(buildingID: buildingID, withWorldMap: hasMap)
            let manifest = try XCTUnwrap(cache.manifest(buildingID: buildingID))
            let graph = MapPackageBuilder.graph(from: manifest)
            let room = try XCTUnwrap(graph.nodes.first { $0.type == .room })

            let picked = try XCTUnwrap(
                BuildingLocalizationService.locate(
                    manuallySelectedNodeID: room.id, manifest: manifest, graph: graph
                )
            )
            let options = try ShortestPathService.findBestEgressRoute(
                from: picked.routePosition, graph: graph, profile: .standard
            )
            XCTAssertNotNil(
                options.best.destination,
                "manual selection must start an evacuation with hasWorldMap=\(hasMap)"
            )
            XCTAssertEqual(cache.hasUsableWorldMap(buildingID: buildingID), hasMap)
        }
    }

    /// Camera relocalization is the one thing a world map genuinely gates.
    func testOnlyRelocalizationDependsOnTheWorldMap() throws {
        let withMap = try storePackage(buildingID: UUID(), withWorldMap: true)
        let withoutMap = try storePackage(buildingID: UUID(), withWorldMap: false)

        XCTAssertEqual(BuildingLocalizationService.relocalizableZones(in: withMap).count, 1)
        XCTAssertTrue(
            BuildingLocalizationService.relocalizableZones(in: withoutMap).isEmpty,
            "a routing-only package must never offer camera relocalization"
        )

        // But OCR and manual selection still work on the routing-only package.
        let graph = MapPackageBuilder.graph(from: withoutMap)
        let room = try XCTUnwrap(graph.nodes.first { $0.type == .room })
        XCTAssertNotNil(
            BuildingLocalizationService.locate(
                recognizedText: ["Room 214"], manifest: withoutMap, graph: graph
            )
        )
        XCTAssertNotNil(
            BuildingLocalizationService.locate(
                manuallySelectedNodeID: room.id, manifest: withoutMap, graph: graph
            )
        )
    }

    // MARK: - Publication carries the world map through

    func testPublishingIncludesTheWorldMapWhenTheZoneHasOne() throws {
        let zoneRoot = root.appendingPathComponent("zones")
        let store = ZoneFileStore(root: zoneRoot)
        let zone = MappingZone(campus: "M", building: "Wade", floor: "2", zoneName: "East")
        try store.saveZone(zone)
        try worldMapBytes.write(
            to: store.url(zone.id, "worldmap.arexperience")
        )

        let artifacts = MapPublisher.artifacts(for: zone, store: store)
        let worldMap = try XCTUnwrap(artifacts.first { $0.kind == .worldmap })
        XCTAssertEqual(worldMap.data, worldMapBytes, "the exact saved bytes must be uploaded")
    }

    func testPublishingAZoneWithoutAWorldMapStillProducesAUsablePackage() throws {
        let zoneRoot = root.appendingPathComponent("zones2")
        let store = ZoneFileStore(root: zoneRoot)
        let zone = MappingZone(campus: "M", building: "Wade", floor: "2", zoneName: "East")
        try store.saveZone(zone)

        let artifacts = MapPublisher.artifacts(for: zone, store: store)
        XCTAssertTrue(artifacts.contains { $0.kind == .worldmap } == false)

        let room = RouteNode(name: "Room 214", type: .room, position: at(0), zoneID: zone.id)
        let exit = RouteNode(name: "Exit", type: .exit, position: at(8), zoneID: zone.id)
        let manifest = try MapPackageBuilder.build(
            zone: zone,
            graph: BuildingGraph(
                zoneID: zone.id, nodes: [room, exit],
                edges: [RouteEdge(fromNodeID: room.id, toNodeID: exit.id, distanceMeters: 8)]
            ),
            buildingID: UUID(), buildingName: "Wade", mapVersionID: UUID(), version: 1,
            artifacts: artifacts
        )
        XCTAssertFalse(manifest.zones[0].hasWorldMap)
        XCTAssertEqual(manifest.nodes.count, 2, "routing data publishes regardless")
    }

    /// The bytes must survive the full publish → download → restore round trip
    /// unchanged, or ARKit will refuse them on device.
    func testWorldMapBytesSurviveTheRoundTripUnchanged() throws {
        let buildingID = UUID()
        let manifest = try storePackage(buildingID: buildingID, withWorldMap: true)
        let artifact = try XCTUnwrap(manifest.artifacts.first { $0.kind == .worldmap })

        XCTAssertEqual(artifact.byteSize, worldMapBytes.count)
        XCTAssertEqual(artifact.checksum, PackageChecksum.sha256(worldMapBytes))
        XCTAssertEqual(cache.worldMapData(buildingID: buildingID), worldMapBytes)
    }
}
