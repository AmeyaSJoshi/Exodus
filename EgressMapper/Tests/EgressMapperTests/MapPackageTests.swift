import XCTest
import simd
@testable import EgressMapper

// MARK: - Fixtures

private func transform(_ x: Float, _ z: Float) -> CodableTransform {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(x, 0, z, 1)
    return CodableTransform(m)
}

private func makeZone(floor: String = "1") -> MappingZone {
    MappingZone(campus: "Main", building: "Wade", floor: floor, zoneName: "East Wing")
}

/// Room 214 → hallway → East Exit.
private func makeGraph(zoneID: UUID) -> (BuildingGraph, room: UUID, exit: UUID) {
    let room = RouteNode(name: "Room 214", type: .room, position: transform(0, 0), zoneID: zoneID)
    let hall = RouteNode(name: "Hallway", type: .hallwayPoint, position: transform(5, 0), zoneID: zoneID)
    let exit = RouteNode(name: "East Exit", type: .exit, position: transform(10, 0), zoneID: zoneID)
    let edges = [
        RouteEdge(fromNodeID: room.id, toNodeID: hall.id, distanceMeters: 5),
        RouteEdge(fromNodeID: hall.id, toNodeID: exit.id, distanceMeters: 5),
    ]
    return (BuildingGraph(zoneID: zoneID, nodes: [room, hall, exit], edges: edges), room.id, exit.id)
}

private func worldMapData() -> Data { Data("pretend-arworldmap".utf8) }
private func imageData(_ tag: String) -> Data { Data("jpeg-\(tag)".utf8) }

private func buildManifest(
    buildingID: UUID = UUID(),
    mapVersionID: UUID = UUID(),
    version: Int = 1,
    artifacts: [PendingArtifact] = [],
    aliases: [UUID: [String]] = [:]
) throws -> (MapPackageManifest, BuildingGraph, MappingZone) {
    let zone = makeZone()
    let (graph, _, _) = makeGraph(zoneID: zone.id)
    let manifest = try MapPackageBuilder.build(
        zone: zone, graph: graph,
        buildingID: buildingID, buildingName: "Wade Academic Center",
        mapVersionID: mapVersionID, version: version,
        artifacts: artifacts, aliases: aliases
    )
    return (manifest, graph, zone)
}

// MARK: - Manifest generation

final class MapPackageManifestTests: XCTestCase {

    func testManifestCarriesGraphZoneAndSchemaVersion() throws {
        let (manifest, graph, zone) = try buildManifest()

        XCTAssertEqual(manifest.schemaVersion, MapPackageManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.nodes.count, graph.nodes.count)
        XCTAssertEqual(manifest.edges.count, graph.edges.count)
        XCTAssertEqual(manifest.zones.count, 1)
        XCTAssertEqual(manifest.zones[0].id, zone.id, "the stable zone UUID must survive publication")
        XCTAssertEqual(manifest.defaultFloorID, "1")
        XCTAssertEqual(manifest.buildingName, "Wade Academic Center")
    }

    func testStableNodeAndEdgeUUIDsArePreserved() throws {
        let zone = makeZone()
        let (graph, roomID, exitID) = makeGraph(zoneID: zone.id)
        let manifest = try MapPackageBuilder.build(
            zone: zone, graph: graph, buildingID: UUID(), buildingName: "Wade",
            mapVersionID: UUID(), version: 1, artifacts: []
        )

        XCTAssertEqual(Set(manifest.nodes.map(\.stableID)), Set(graph.nodes.map(\.id)))
        XCTAssertEqual(Set(manifest.edges.map(\.stableID)), Set(graph.edges.map(\.id)))
        XCTAssertTrue(manifest.nodes.contains { $0.stableID == roomID && $0.name == "Room 214" })
        XCTAssertTrue(manifest.nodes.contains { $0.stableID == exitID && $0.type == .exit })
        // Live state references edges by stable id, so these must round-trip too.
        for edge in graph.edges {
            let published = manifest.edges.first { $0.stableID == edge.id }
            XCTAssertEqual(published?.fromNodeStableID, edge.fromNodeID)
            XCTAssertEqual(published?.toNodeStableID, edge.toNodeID)
        }
    }

    func testRebuiltGraphMatchesTheSourceGraph() throws {
        let (manifest, graph, _) = try buildManifest()
        let rebuilt = MapPackageBuilder.graph(from: manifest)

        XCTAssertEqual(Set(rebuilt.nodes.map(\.id)), Set(graph.nodes.map(\.id)))
        XCTAssertEqual(Set(rebuilt.edges.map(\.id)), Set(graph.edges.map(\.id)))
        XCTAssertEqual(rebuilt.exits.count, 1)
        // Positions survive so AR anchors line up with the published graph.
        let original = graph.nodes.first { $0.type == .exit }!
        let copy = rebuilt.node(original.id)!
        XCTAssertEqual(copy.worldPosition.x, original.worldPosition.x, accuracy: 0.0001)
        XCTAssertEqual(copy.worldPosition.z, original.worldPosition.z, accuracy: 0.0001)
    }

    func testDanglingEdgeIsRejectedBeforeAnythingUploads() {
        let zone = makeZone()
        let (graph, _, _) = makeGraph(zoneID: zone.id)
        var broken = graph
        broken.edges.append(
            RouteEdge(fromNodeID: UUID(), toNodeID: graph.nodes[0].id, distanceMeters: 3)
        )

        XCTAssertThrowsError(
            try MapPackageBuilder.build(
                zone: zone, graph: broken, buildingID: UUID(), buildingName: "Wade",
                mapVersionID: UUID(), version: 1, artifacts: []
            )
        ) { error in
            guard case MapPackageError.danglingEdges(let ids) = error else {
                return XCTFail("expected danglingEdges, got \(error)")
            }
            XCTAssertEqual(ids.count, 1)
        }
    }

    func testEmptyGraphIsRejected() {
        let zone = makeZone()
        XCTAssertThrowsError(
            try MapPackageBuilder.build(
                zone: zone, graph: BuildingGraph(zoneID: zone.id, nodes: [], edges: []),
                buildingID: UUID(), buildingName: "Wade", mapVersionID: UUID(),
                version: 1, artifacts: []
            )
        ) { XCTAssertEqual($0 as? MapPackageError, .emptyGraph) }
    }

    func testArtifactsCarrySizeChecksumFloorAndViewpoint() throws {
        let zone = makeZone()
        let (graph, _, _) = makeGraph(zoneID: zone.id)
        let world = PendingArtifact(
            kind: .worldmap, zoneID: zone.id, fileName: "worldmap.arexperience", data: worldMapData()
        )
        let north = PendingArtifact(
            kind: .referenceImage, zoneID: zone.id, fileName: "ref-north.jpg",
            viewpoint: "facing north", data: imageData("north")
        )
        let south = PendingArtifact(
            kind: .referenceImage, zoneID: zone.id, fileName: "ref-south.jpg",
            viewpoint: "facing south", data: imageData("south")
        )

        let buildingID = UUID(), versionID = UUID()
        let manifest = try MapPackageBuilder.build(
            zone: zone, graph: graph, buildingID: buildingID, buildingName: "Wade",
            mapVersionID: versionID, version: 2, artifacts: [world, north, south]
        )

        XCTAssertEqual(manifest.artifacts.count, 3)
        let stored = manifest.artifact(world.id)!
        XCTAssertEqual(stored.byteSize, worldMapData().count)
        XCTAssertEqual(stored.checksum, PackageChecksum.sha256(worldMapData()))
        XCTAssertEqual(stored.floorID, "1")
        XCTAssertEqual(
            stored.storagePath,
            "\(buildingID.uuidString)/\(versionID.uuidString)/worldmap.arexperience",
            "the first path segment is what Storage RLS authorizes against"
        )

        // Multiple viewpoints per zone — the fix for one-exact-view localization.
        XCTAssertEqual(manifest.zones[0].referenceImageArtifactIDs.count, 2)
        XCTAssertEqual(manifest.zones[0].worldMapArtifactID, world.id)
        XCTAssertEqual(manifest.artifact(north.id)?.viewpoint, "facing north")
    }

    func testArtifactForAnUnknownZoneIsRejected() {
        let zone = makeZone()
        let (graph, _, _) = makeGraph(zoneID: zone.id)
        let stray = PendingArtifact(
            kind: .referenceImage, zoneID: UUID(), fileName: "stray.jpg", data: imageData("x")
        )
        XCTAssertThrowsError(
            try MapPackageBuilder.build(
                zone: zone, graph: graph, buildingID: UUID(), buildingName: "Wade",
                mapVersionID: UUID(), version: 1, artifacts: [stray]
            )
        )
    }

    func testRoomNumbersAndAliasesAreIndexedForOCR() throws {
        let zone = makeZone()
        let (graph, roomID, _) = makeGraph(zoneID: zone.id)
        let manifest = try MapPackageBuilder.build(
            zone: zone, graph: graph, buildingID: UUID(), buildingName: "Wade",
            mapVersionID: UUID(), version: 1, artifacts: [],
            aliases: [roomID: ["Rm. 214", "Lecture Hall"]]
        )

        let room = manifest.nodes.first { $0.stableID == roomID }!
        XCTAssertEqual(room.roomNumber, "214")
        XCTAssertTrue(room.aliases.contains("Lecture Hall"))

        let index = manifest.aliasIndex
        XCTAssertEqual(index[MapPackageManifest.normalize("RM 214")], roomID)
        XCTAssertEqual(index[MapPackageManifest.normalize("room 214")], roomID)
        XCTAssertEqual(index[MapPackageManifest.normalize("lecture hall")], roomID)
    }

    func testAccessibilityMetadataFollowsNodeType() throws {
        let zone = makeZone()
        let stair = RouteNode(name: "North Stairs", type: .stairwell, position: transform(0, 0), zoneID: zone.id)
        let exit = RouteNode(name: "Exit", type: .exit, position: transform(4, 0), zoneID: zone.id)
        let graph = BuildingGraph(
            zoneID: zone.id, nodes: [stair, exit],
            edges: [RouteEdge(
                fromNodeID: stair.id, toNodeID: exit.id, distanceMeters: 4,
                accessibility: EdgeAccessibility.between(.stairwell, .exit)
            )]
        )
        let manifest = try MapPackageBuilder.build(
            zone: zone, graph: graph, buildingID: UUID(), buildingName: "Wade",
            mapVersionID: UUID(), version: 1, artifacts: []
        )

        let published = manifest.nodes.first { $0.stableID == stair.id }!
        XCTAssertTrue(published.accessibility.hasStairs)
        XCTAssertFalse(published.accessibility.wheelchairAccessible)
        XCTAssertTrue(manifest.edges[0].containsStairs)
        XCTAssertFalse(manifest.edges[0].wheelchairAccessible)
    }

    func testManifestRoundTripsThroughJSON() throws {
        let (manifest, _, _) = try buildManifest(
            artifacts: [PendingArtifact(kind: .worldmap, fileName: "w.bin", data: worldMapData())]
        )
        let decoded = try MapPackageCoder.decode(try MapPackageCoder.encode(manifest))
        XCTAssertEqual(decoded, manifest)
    }
}

// MARK: - Verification

final class MapPackageValidatorTests: XCTestCase {

    func testValidPackageVerifies() throws {
        let world = PendingArtifact(kind: .worldmap, fileName: "w.bin", data: worldMapData())
        let (manifest, _, _) = try buildManifest(artifacts: [world])
        let path = manifest.artifact(world.id)!.storagePath
        XCTAssertNoThrow(
            try MapPackageValidator.verify(manifest: manifest, files: [path: worldMapData()])
        )
    }

    func testCorruptedBytesFailTheChecksum() throws {
        let world = PendingArtifact(kind: .worldmap, fileName: "w.bin", data: worldMapData())
        let (manifest, _, _) = try buildManifest(artifacts: [world])
        let path = manifest.artifact(world.id)!.storagePath

        XCTAssertThrowsError(
            try MapPackageValidator.verify(
                manifest: manifest, files: [path: Data("corrupted-but-same-lengthh".utf8)]
            )
        ) { error in
            guard case MapPackageError.checksumMismatch = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }
    }

    func testMissingArtifactFailsVerification() throws {
        let world = PendingArtifact(kind: .worldmap, fileName: "w.bin", data: worldMapData())
        let (manifest, _, _) = try buildManifest(artifacts: [world])
        XCTAssertThrowsError(try MapPackageValidator.verify(manifest: manifest, files: [:]))
    }

    func testNewerSchemaVersionIsRejected() throws {
        var (manifest, _, _) = try buildManifest()
        manifest.schemaVersion = MapPackageManifest.currentSchemaVersion + 1
        XCTAssertFalse(manifest.isSchemaSupported)
        XCTAssertThrowsError(try MapPackageValidator.verify(manifest: manifest, files: [:])) {
            XCTAssertEqual(
                $0 as? MapPackageError,
                .unsupportedSchema(MapPackageManifest.currentSchemaVersion + 1)
            )
        }
    }
}

// MARK: - Upload authorization and ordering

/// Records every call so the ordering guarantees can be asserted, and can be
/// told to fail at a chosen step.
private actor FakeUploader: MapPackageUploading {
    enum Step: Equatable { case upload(String), remove([String]), artifacts(Int), aliases(Int), publish }

    enum Failure: Equatable { case none, uploadAt(Int), recordArtifacts, publish, unauthorized }

    private(set) var steps: [Step] = []
    private(set) var storedObjects: Set<String> = []
    private var uploadCount = 0
    private let failure: Failure

    init(failure: Failure = .none) { self.failure = failure }

    struct NotAuthorized: LocalizedError, Equatable {
        var errorDescription: String? { "Only an administrator or mapper can publish maps." }
    }

    func upload(path: String, data: Data, contentType: String) async throws {
        if failure == .unauthorized { throw NotAuthorized() }
        if case .uploadAt(let index) = failure, index == uploadCount {
            uploadCount += 1
            throw URLError(.networkConnectionLost)
        }
        uploadCount += 1
        steps.append(.upload(path))
        storedObjects.insert(path)
    }

    func remove(paths: [String]) async {
        steps.append(.remove(paths))
        for path in paths { storedObjects.remove(path) }
    }

    func recordArtifacts(_ artifacts: [PackageArtifact], manifest: MapPackageManifest) async throws {
        if failure == .recordArtifacts { throw URLError(.badServerResponse) }
        steps.append(.artifacts(artifacts.count))
    }

    func recordAliases(_ aliases: [UUID: [String]], mapVersionID: UUID) async throws {
        steps.append(.aliases(aliases.count))
    }

    func publishVersion(mapVersionID: UUID) async throws {
        if failure == .publish { throw URLError(.badServerResponse) }
        steps.append(.publish)
    }

    var publishedAtLeastOnce: Bool { steps.contains(.publish) }
    var allSteps: [Step] { steps }
    var objects: Set<String> { storedObjects }
}

final class MapPackagePublisherTests: XCTestCase {

    private func pending() -> [PendingArtifact] {
        [
            PendingArtifact(kind: .worldmap, fileName: "worldmap.arexperience", data: worldMapData()),
            PendingArtifact(kind: .referenceImage, fileName: "ref-north.jpg", viewpoint: "north", data: imageData("n")),
        ]
    }

    func testPublishUploadsEveryArtifactAndTheManifestBeforePublishing() async throws {
        let artifacts = pending()
        let (manifest, _, _) = try buildManifest(artifacts: artifacts)
        let uploader = FakeUploader()

        let outcome = try await MapPackagePublisher(uploader: uploader).publish(
            manifest: manifest, artifacts: artifacts, aliases: [UUID(): ["214"]]
        )

        // Two binaries plus manifest.json.
        XCTAssertEqual(outcome.uploadedPaths.count, 3)
        XCTAssertEqual(outcome.artifactCount, 3)
        XCTAssertTrue(outcome.uploadedPaths.contains { $0.hasSuffix("manifest.json") })

        let steps = await uploader.allSteps
        let publishIndex = steps.firstIndex(of: .publish)
        XCTAssertNotNil(publishIndex)
        let uploadIndexes = steps.indices.filter {
            if case .upload = steps[$0] { return true } else { return false }
        }
        XCTAssertTrue(
            uploadIndexes.allSatisfy { $0 < publishIndex! },
            "every upload must complete before the version is published"
        )
        XCTAssertTrue(steps.contains(.artifacts(3)), "each stored object gets a database row")
    }

    func testInterruptedUploadLeavesTheVersionUnpublishedAndCleansUp() async throws {
        let artifacts = pending()
        let (manifest, _, _) = try buildManifest(artifacts: artifacts)
        let uploader = FakeUploader(failure: .uploadAt(1))

        do {
            _ = try await MapPackagePublisher(uploader: uploader).publish(
                manifest: manifest, artifacts: artifacts
            )
            XCTFail("expected the interrupted upload to throw")
        } catch {
            // expected
        }

        let published = await uploader.publishedAtLeastOnce
        XCTAssertFalse(published, "a partial upload must never be published")
        let leftovers = await uploader.objects
        XCTAssertTrue(leftovers.isEmpty, "partially uploaded objects are cleaned up")
    }

    func testFailureRecordingArtifactRowsAlsoLeavesTheVersionUnpublished() async throws {
        let artifacts = pending()
        let (manifest, _, _) = try buildManifest(artifacts: artifacts)
        let uploader = FakeUploader(failure: .recordArtifacts)

        do {
            _ = try await MapPackagePublisher(uploader: uploader).publish(
                manifest: manifest, artifacts: artifacts
            )
            XCTFail("expected a throw")
        } catch {}

        let published = await uploader.publishedAtLeastOnce
        XCTAssertFalse(published)
        let leftovers = await uploader.objects
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testUnauthorizedUploaderNeverPublishes() async throws {
        let artifacts = pending()
        let (manifest, _, _) = try buildManifest(artifacts: artifacts)
        let uploader = FakeUploader(failure: .unauthorized)

        do {
            _ = try await MapPackagePublisher(uploader: uploader).publish(
                manifest: manifest, artifacts: artifacts
            )
            XCTFail("an occupant must not be able to upload map artifacts")
        } catch {
            XCTAssertTrue(error is FakeUploader.NotAuthorized)
        }
        let published = await uploader.publishedAtLeastOnce
        XCTAssertFalse(published)
    }

    func testPublishingAnUpdateTargetsANewVersionAndLeavesOldPathsAlone() async throws {
        let buildingID = UUID()
        let v1Artifacts = pending()
        let (v1, _, _) = try buildManifest(
            buildingID: buildingID, mapVersionID: UUID(), version: 1, artifacts: v1Artifacts
        )
        let v2Artifacts = pending()
        let (v2, _, _) = try buildManifest(
            buildingID: buildingID, mapVersionID: UUID(), version: 2, artifacts: v2Artifacts
        )

        let uploader = FakeUploader()
        let publisher = MapPackagePublisher(uploader: uploader)
        let first = try await publisher.publish(manifest: v1, artifacts: v1Artifacts)
        let second = try await publisher.publish(manifest: v2, artifacts: v2Artifacts)

        XCTAssertNotEqual(v1.mapVersionID, v2.mapVersionID)
        XCTAssertTrue(
            Set(first.uploadedPaths).isDisjoint(with: Set(second.uploadedPaths)),
            "a new version writes to its own paths — the old one is never overwritten"
        )
        let stored = await uploader.objects
        XCTAssertEqual(stored.count, 6, "both versions remain in Storage")
    }
}

// MARK: - Download and cache

private actor FakeSource: MapPackageFetching {
    enum Failure: Equatable { case none, manifest, downloadAt(Int), corruptAt(Int) }

    private let manifestValue: MapPackageManifest
    private let files: [String: Data]
    private let failure: Failure
    private var downloads = 0

    init(manifest: MapPackageManifest, files: [String: Data], failure: Failure = .none) {
        self.manifestValue = manifest
        self.files = files
        self.failure = failure
    }

    func manifest(buildingID: UUID, mapVersionID: UUID) async throws -> MapPackageManifest {
        if failure == .manifest { throw URLError(.notConnectedToInternet) }
        return manifestValue
    }

    func download(path: String) async throws -> Data {
        defer { downloads += 1 }
        if case .downloadAt(let index) = failure, index == downloads {
            throw URLError(.networkConnectionLost)
        }
        if case .corruptAt(let index) = failure, index == downloads {
            return Data("corrupted".utf8)
        }
        guard let data = files[path] else { throw URLError(.fileDoesNotExist) }
        return data
    }
}

final class MapPackageDownloadTests: XCTestCase {

    private var cacheRoot: URL!
    private var cache: MapPackageCache!

    override func setUpWithError() throws {
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("egress-packages-\(UUID().uuidString)")
        cache = MapPackageCache(root: cacheRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    private func package(
        buildingID: UUID, version: Int
    ) throws -> (MapPackageManifest, [String: Data]) {
        let artifacts = [
            PendingArtifact(kind: .worldmap, fileName: "worldmap.arexperience", data: Data("world-v\(version)".utf8)),
            PendingArtifact(kind: .referenceImage, fileName: "ref-north.jpg", viewpoint: "north", data: imageData("n\(version)")),
        ]
        let (manifest, _, _) = try buildManifest(
            buildingID: buildingID, version: version, artifacts: artifacts
        )
        var files: [String: Data] = [:]
        for item in artifacts {
            files[manifest.artifact(item.id)!.storagePath] = item.data
        }
        return (manifest, files)
    }

    func testSuccessfulDownloadCachesAndVerifies() async throws {
        let buildingID = UUID()
        let (manifest, files) = try package(buildingID: buildingID, version: 1)
        let downloader = MapPackageDownloader(
            source: FakeSource(manifest: manifest, files: files), cache: cache
        )

        let outcome = try await downloader.download(
            buildingID: buildingID, mapVersionID: manifest.mapVersionID
        )

        XCTAssertEqual(outcome.version, 1)
        XCTAssertTrue(cache.isOfflineAvailable(buildingID: buildingID))
        XCTAssertEqual(cache.cachedVersion(buildingID: buildingID), 1)

        let cached = cache.manifest(buildingID: buildingID)
        XCTAssertEqual(cached, manifest)
        // The world map bytes are on disk and pass their own checksum.
        let worldArtifact = manifest.artifacts.first { $0.kind == .worldmap }!
        XCTAssertEqual(
            cache.data(for: worldArtifact, buildingID: buildingID, version: 1),
            Data("world-v1".utf8)
        )
    }

    func testCachedPackageLoadsOfflineWithNoSourceCalls() async throws {
        let buildingID = UUID()
        let (manifest, files) = try package(buildingID: buildingID, version: 1)
        try cache.store(manifest: manifest, files: files)

        // No network object involved at all — this is what Emergency uses.
        let loaded = cache.manifest(buildingID: buildingID)
        XCTAssertNotNil(loaded)
        let graph = MapPackageBuilder.graph(from: loaded!)
        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertEqual(graph.exits.count, 1)
    }

    func testCorruptedDownloadDoesNotReplaceTheCachedVersion() async throws {
        let buildingID = UUID()
        let (v1, v1Files) = try package(buildingID: buildingID, version: 1)
        try cache.store(manifest: v1, files: v1Files)

        let (v2, v2Files) = try package(buildingID: buildingID, version: 2)
        let downloader = MapPackageDownloader(
            source: FakeSource(manifest: v2, files: v2Files, failure: .corruptAt(0)), cache: cache
        )

        do {
            _ = try await downloader.download(buildingID: buildingID, mapVersionID: v2.mapVersionID)
            XCTFail("a corrupted artifact must not be accepted")
        } catch let failure as MapPackageDownloadFailure {
            XCTAssertEqual(failure.keptCachedVersion, 1)
        }

        XCTAssertEqual(cache.cachedVersion(buildingID: buildingID), 1, "v1 survives the failed update")
        XCTAssertEqual(cache.manifest(buildingID: buildingID), v1)
    }

    func testInterruptedDownloadKeepsThePreviousVersion() async throws {
        let buildingID = UUID()
        let (v1, v1Files) = try package(buildingID: buildingID, version: 1)
        try cache.store(manifest: v1, files: v1Files)

        let (v2, v2Files) = try package(buildingID: buildingID, version: 2)
        let downloader = MapPackageDownloader(
            source: FakeSource(manifest: v2, files: v2Files, failure: .downloadAt(1)), cache: cache
        )

        do {
            _ = try await downloader.download(buildingID: buildingID, mapVersionID: v2.mapVersionID)
            XCTFail("expected the interrupted download to throw")
        } catch {}

        XCTAssertEqual(cache.cachedVersion(buildingID: buildingID), 1)
        XCTAssertNil(cache.manifest(buildingID: buildingID, version: 2))
    }

    func testFirstDownloadFailureLeavesNothingCached() async throws {
        let buildingID = UUID()
        let (manifest, files) = try package(buildingID: buildingID, version: 1)
        let downloader = MapPackageDownloader(
            source: FakeSource(manifest: manifest, files: files, failure: .downloadAt(0)), cache: cache
        )

        do {
            _ = try await downloader.download(buildingID: buildingID, mapVersionID: manifest.mapVersionID)
            XCTFail("expected a throw")
        } catch {
            XCTAssertFalse(error is MapPackageDownloadFailure, "there was no previous version to keep")
        }
        XCTAssertFalse(cache.isOfflineAvailable(buildingID: buildingID))
    }

    func testUnsupportedSchemaIsRejectedBeforeAnyArtifactDownloads() async throws {
        let buildingID = UUID()
        var (manifest, files) = try package(buildingID: buildingID, version: 1)
        manifest.schemaVersion = 99
        let downloader = MapPackageDownloader(
            source: FakeSource(manifest: manifest, files: files), cache: cache
        )

        do {
            _ = try await downloader.download(buildingID: buildingID, mapVersionID: manifest.mapVersionID)
            XCTFail("expected unsupportedSchema")
        } catch {
            XCTAssertEqual(error as? MapPackageError, .unsupportedSchema(99))
        }
        XCTAssertFalse(cache.isOfflineAvailable(buildingID: buildingID))
    }

    func testUpdateReplacesTheOlderVersionOnceVerified() async throws {
        let buildingID = UUID()
        let (v1, v1Files) = try package(buildingID: buildingID, version: 1)
        try cache.store(manifest: v1, files: v1Files)

        let (v2, v2Files) = try package(buildingID: buildingID, version: 2)
        let downloader = MapPackageDownloader(
            source: FakeSource(manifest: v2, files: v2Files), cache: cache
        )
        let outcome = try await downloader.download(
            buildingID: buildingID, mapVersionID: v2.mapVersionID
        )

        XCTAssertEqual(outcome.version, 2)
        XCTAssertEqual(cache.cachedVersions(buildingID: buildingID), [2], "the stale copy is pruned")
    }

    func testRemovingADownloadClearsOnlyThatBuilding() async throws {
        let a = UUID(), b = UUID()
        let (packageA, filesA) = try package(buildingID: a, version: 1)
        let (packageB, filesB) = try package(buildingID: b, version: 1)
        try cache.store(manifest: packageA, files: filesA)
        try cache.store(manifest: packageB, files: filesB)

        cache.remove(buildingID: a)

        XCTAssertFalse(cache.isOfflineAvailable(buildingID: a))
        XCTAssertTrue(cache.isOfflineAvailable(buildingID: b))
        XCTAssertEqual(cache.allCachedVersions(), [b: 1])
    }

    func testStagingDirectoryWithoutAManifestIsIgnored() throws {
        let buildingID = UUID()
        let stale = cache.versionDirectory(buildingID, version: 3)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: stale.appendingPathComponent("worldmap.arexperience"))

        XCTAssertEqual(cache.cachedVersions(buildingID: buildingID), [], "a partial write is not usable")
        XCTAssertFalse(cache.isOfflineAvailable(buildingID: buildingID))
    }
}
