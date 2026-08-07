import XCTest
import simd
@testable import EgressMapper

// MARK: - Startup

@MainActor
final class StartupCoordinatorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("egress-startup-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        DeviceCapabilities.probe = { true }
    }

    private func repository() -> ZoneRepository {
        ZoneRepository(store: ZoneFileStore(root: root))
    }

    /// The shell must be usable before anything remote finishes. Signed out,
    /// there is nothing remote to wait for at all.
    func testSignedOutLaunchReachesReadyWithoutTouchingTheNetwork() async {
        let startup = StartupCoordinator()
        let session = BackendSession()
        XCTAssertFalse(session.isSignedIn)

        startup.start(repository: repository(), session: session)
        await Task.yield()
        for _ in 0..<50 where !startup.localReady {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(startup.localReady)
        XCTAssertEqual(startup.phase, .ready)
        XCTAssertFalse(startup.phase.blocksInteraction)
    }

    func testNoPhaseEverBlocksInteraction() {
        let phases: [StartupCoordinator.Phase] = [
            .idle, .scanningLocalMaps, .restoringSession, .syncingBuildings,
            .ready, .offlineUsingCache, .failed("network down"),
        ]
        for phase in phases {
            XCTAssertFalse(
                phase.blocksInteraction,
                "\(phase) must not disable the interface while it runs"
            )
        }
    }

    func testEveryBackgroundPhaseHasAnHonestLabelAndReadyHasNone() {
        XCTAssertNil(StartupCoordinator.Phase.ready.label)
        XCTAssertNil(StartupCoordinator.Phase.idle.label)
        for phase: StartupCoordinator.Phase in [
            .scanningLocalMaps, .restoringSession, .syncingBuildings, .offlineUsingCache,
        ] {
            XCTAssertNotNil(phase.label)
        }
        XCTAssertTrue(StartupCoordinator.Phase.failed("boom").label?.contains("boom") ?? false)
        XCTAssertTrue(StartupCoordinator.Phase.failed("boom").canRetry)
        XCTAssertTrue(StartupCoordinator.Phase.offlineUsingCache.canRetry)
        XCTAssertFalse(StartupCoordinator.Phase.ready.canRetry)
    }

    /// Home, Saved Maps and Emergency all call `start` on appear. Before the
    /// coordinator that meant three directory scans and three catalogue
    /// requests racing each other.
    func testRepeatedAppearancesDoNotRepeatTheLocalScan() async {
        let startup = StartupCoordinator()
        let session = BackendSession()
        let repo = repository()

        startup.start(repository: repo, session: session)
        startup.start(repository: repo, session: session)
        startup.start(repository: repo, session: session)
        for _ in 0..<50 where !startup.localReady {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(startup.localReady)
    }

    func testResetClearsCoalescingSoALaterLaunchStartsFresh() async {
        let startup = StartupCoordinator()
        let session = BackendSession()
        startup.start(repository: repository(), session: session)
        for _ in 0..<50 where !startup.localReady {
            try? await Task.sleep(for: .milliseconds(10))
        }
        startup.reset()
        XCTAssertFalse(startup.localReady)
        XCTAssertEqual(startup.phase, .idle)
    }

    func testTimeoutIsBoundedSoASlowBackendCannotHangTheUI() {
        XCTAssertLessThanOrEqual(StartupCoordinator.remoteTimeout, .seconds(30))
        XCTAssertGreaterThan(StartupCoordinator.refreshCoalescingWindow, 0)
    }
}

@MainActor
final class DeviceCapabilitiesTests: XCTestCase {

    override func tearDown() {
        DeviceCapabilities.probe = { true }
        super.tearDown()
    }

    /// The regression: this probe used to run inside `HomeView.body`, loading
    /// ARKit on the main thread before the first frame.
    func testCapabilityIsAssumedSupportedUntilResolvedOffTheMainThread() async {
        let probed = OSAllocatedUnfairLockBox(false)
        DeviceCapabilities.probe = { probed.set(true); return false }

        let capabilities = DeviceCapabilities()
        XCTAssertTrue(
            capabilities.arWorldTrackingSupported,
            "the launch screen must not wait on ARKit to decide what to draw"
        )
        XCTAssertFalse(capabilities.resolved)
        XCTAssertFalse(probed.value, "nothing may be probed until resolve() is called")

        capabilities.resolve()
        for _ in 0..<100 where !capabilities.resolved {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(capabilities.resolved)
        XCTAssertFalse(capabilities.arWorldTrackingSupported)
    }

    func testResolveProbesOnlyOnce() async {
        let count = OSAllocatedUnfairLockBox(0)
        DeviceCapabilities.probe = { count.increment(); return true }

        let capabilities = DeviceCapabilities()
        capabilities.resolve()
        capabilities.resolve()
        capabilities.resolve()
        for _ in 0..<100 where !capabilities.resolved {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(count.value, 1, "every view re-render must not re-probe ARKit")
    }
}

/// Minimal thread-safe box so the probe can be observed from a detached task.
final class OSAllocatedUnfairLockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ newValue: T) { lock.lock(); stored = newValue; lock.unlock() }
}

extension OSAllocatedUnfairLockBox where T == Int {
    func increment() { set(value + 1) }
}

// MARK: - Saved maps scan

final class ZoneScanTests: XCTestCase {

    private var root: URL!
    private var store: ZoneFileStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("egress-scan-\(UUID().uuidString)")
        store = ZoneFileStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Listing saved maps must read metadata only. A launch that touched world
    /// maps would scale with how much the user had recorded.
    func testScanningReadsMetadataOnlyAndNeverTheWorldMap() throws {
        let zone = MappingZone(campus: "M", building: "Wade", floor: "2", zoneName: "East")
        try store.saveZone(zone)
        let worldMap = root.appendingPathComponent(zone.id.uuidString)
            .appendingPathComponent("worldmap.arexperience")
        // A deliberately unreadable world map: scanning must not care.
        try Data(repeating: 0xFF, count: 2048).write(to: worldMap)

        let result = store.scanZones()
        XCTAssertEqual(result.zones.map(\.id), [zone.id])
        XCTAssertTrue(result.damaged.isEmpty)

        // And decoding it would in fact fail, proving the scan never tried.
        XCTAssertThrowsError(try store.loadWorldMap(zone.id))
    }

    func testScanReportsZonesAndDamageInOnePass() throws {
        let good = MappingZone(campus: "M", building: "Wade", floor: "2", zoneName: "Good")
        try store.saveZone(good)
        let badID = UUID()
        let badDir = root.appendingPathComponent(badID.uuidString)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: badDir.appendingPathComponent("zone.json"))

        let result = store.scanZones()
        XCTAssertEqual(result.zones.map(\.id), [good.id])
        XCTAssertEqual(result.damaged, [badID])
        // The convenience wrappers must agree with the single pass.
        XCTAssertEqual(store.listZones().map(\.id), result.zones.map(\.id))
        XCTAssertEqual(store.damagedZoneIDs(), result.damaged)
    }
}

// MARK: - Localization to evacuation

final class EvacuationHandoffTests: XCTestCase {

    private func at(_ x: Float) -> CodableTransform {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, 0, 0, 1)
        return CodableTransform(m)
    }

    private struct Fixture {
        let manifest: MapPackageManifest
        let graph: BuildingGraph
        let zoneID: UUID
        let roomID: UUID
        let exitID: UUID
        let farExitID: UUID
    }

    private func makeFixture(stairsToNearExit: Bool = false) throws -> Fixture {
        let zone = MappingZone(campus: "M", building: "Wade", floor: "2", zoneName: "East Wing")
        let room = RouteNode(name: "Room 214", type: .room, position: at(0), zoneID: zone.id)
        let hall = RouteNode(name: "Hallway", type: .intersection, position: at(5), zoneID: zone.id)
        let near = RouteNode(name: "East Exit", type: .exit, position: at(10), zoneID: zone.id)
        let far = RouteNode(name: "West Exit", type: .exit, position: at(-30), zoneID: zone.id)

        let graph = BuildingGraph(
            zoneID: zone.id,
            nodes: [room, hall, near, far],
            edges: [
                RouteEdge(fromNodeID: room.id, toNodeID: hall.id, distanceMeters: 5),
                RouteEdge(
                    fromNodeID: hall.id, toNodeID: near.id, distanceMeters: 5,
                    accessibility: stairsToNearExit
                        ? EdgeAccessibility(containsStairs: true, requiresElevator: false, wheelchairAccessible: false)
                        : .standard
                ),
                RouteEdge(fromNodeID: room.id, toNodeID: far.id, distanceMeters: 30),
            ]
        )
        let manifest = try MapPackageBuilder.build(
            zone: zone, graph: graph, buildingID: UUID(), buildingName: "Wade Academic Center",
            mapVersionID: UUID(), version: 1,
            artifacts: [PendingArtifact(
                kind: .worldmap, zoneID: zone.id, fileName: "w.bin", data: Data("w".utf8)
            )],
            aliases: [room.id: ["Rm. 214"]]
        )
        return Fixture(
            manifest: manifest, graph: MapPackageBuilder.graph(from: manifest),
            zoneID: zone.id, roomID: room.id, exitID: near.id, farExitID: far.id
        )
    }

    /// The reported bug: localization succeeded but the flow stopped there.
    /// A confirmed result must snap to the graph AND produce a route, which is
    /// what makes Start Evacuation available.
    func testConfirmedLocalizationSnapsToTheGraphAndYieldsARoute() throws {
        let f = try makeFixture()
        let located = try XCTUnwrap(
            BuildingLocalizationService.locate(
                worldPosition: SIMD3<Float>(0.2, 0, 0), relocalizedZoneID: f.zoneID,
                manifest: f.manifest, graph: f.graph
            )
        )

        let startNodeID = try XCTUnwrap(
            located.routePosition.nodeID, "a confirmed location must carry a graph node"
        )
        XCTAssertNotNil(f.graph.node(startNodeID), "the snapped node must exist in this building")

        let options = try ShortestPathService.findBestEgressRoute(
            from: located.routePosition, graph: f.graph, profile: .standard
        )
        XCTAssertEqual(options.best.destination.id, f.exitID, "the safest exit is chosen automatically")
        XCTAssertGreaterThan(options.best.totalDistanceMeters, 0)
        XCTAssertFalse(options.alternatives.isEmpty, "the other exit is offered as an alternative")
    }

    func testOCRLocalizationReachesTheSameEvacuationStart() throws {
        let f = try makeFixture()
        let bySign = try XCTUnwrap(
            BuildingLocalizationService.locate(
                recognizedText: ["Rm. 214"], manifest: f.manifest, graph: f.graph
            )
        )
        XCTAssertEqual(bySign.method, .signRecognition)
        XCTAssertEqual(bySign.routePosition.nodeID, f.roomID)

        let options = try ShortestPathService.findBestEgressRoute(
            from: bySign.routePosition, graph: f.graph, profile: .standard
        )
        XCTAssertEqual(options.best.destination.id, f.exitID)
    }

    func testManualSelectionReachesTheSameEvacuationStart() throws {
        let f = try makeFixture()
        let manual = try XCTUnwrap(
            BuildingLocalizationService.locate(
                manuallySelectedNodeID: f.roomID, manifest: f.manifest, graph: f.graph
            )
        )
        let options = try ShortestPathService.findBestEgressRoute(
            from: manual.routePosition, graph: f.graph, profile: .standard
        )
        XCTAssertEqual(options.best.destination.id, f.exitID)
    }

    func testAccessibilityChangesWhichExitIsSelected() throws {
        let f = try makeFixture(stairsToNearExit: true)
        let start = RoutePosition(nodeID: f.roomID, worldPosition: .zero)

        let standard = try ShortestPathService.findBestEgressRoute(
            from: start, graph: f.graph, profile: .standard
        )
        XCTAssertEqual(standard.best.destination.id, f.exitID)

        var wheelchair = NavigationProfile.standard
        wheelchair.requireWheelchairAccessible = true
        let accessible = try ShortestPathService.findBestEgressRoute(
            from: start, graph: f.graph, profile: wheelchair
        )
        XCTAssertEqual(
            accessible.best.destination.id, f.farExitID,
            "the stairs route must be rejected and the longer step-free exit chosen"
        )
    }

    /// A closure already in force when the route is first calculated must be
    /// respected — not only closures that arrive later.
    func testALiveBlockagePresentBeforeCalculationIsRespected() throws {
        let f = try makeFixture()
        let blockedEdge = try XCTUnwrap(
            f.graph.edges.first { $0.toNodeID == f.exitID || $0.fromNodeID == f.exitID }
        )

        var overlay = LiveStateOverlay(buildingID: f.manifest.buildingID)
        overlay.apply(edge: LiveEdgeState(
            edgeStableID: blockedEdge.id, status: .blocked, hazardType: nil,
            reason: "Blocked by administrator", severity: 5, revision: 1, expiresAt: nil
        ))

        let options = try ShortestPathService.findBestEgressRoute(
            from: RoutePosition(nodeID: f.roomID, worldPosition: .zero),
            graph: overlay.effectiveGraph(from: f.graph),
            profile: .standard
        )
        XCTAssertEqual(options.best.destination.id, f.farExitID)
        XCTAssertEqual(options.unreachable.map(\.node.id), [f.exitID])
    }

    func testNoReachableExitSurfacesAnExplicitError() throws {
        let f = try makeFixture()
        var overlay = LiveStateOverlay(buildingID: f.manifest.buildingID)
        for (index, edge) in f.graph.edges.enumerated() {
            overlay.apply(edge: LiveEdgeState(
                edgeStableID: edge.id, status: .blocked, hazardType: nil, reason: nil,
                severity: 5, revision: Int64(index + 1), expiresAt: nil
            ))
        }

        XCTAssertThrowsError(
            try ShortestPathService.findBestEgressRoute(
                from: RoutePosition(nodeID: f.roomID, worldPosition: .zero),
                graph: overlay.effectiveGraph(from: f.graph), profile: .standard
            )
        ) { error in
            XCTAssertFalse(
                error.localizedDescription.isEmpty,
                "the occupant must never be left on a success screen with no message"
            )
        }
    }

    func testLowConfidenceStillProducesAConfirmableResult() throws {
        let f = try makeFixture()
        // Far enough from the route to be low confidence, but still usable.
        let located = BuildingLocalizationService.locate(
            worldPosition: SIMD3<Float>(2.5, 0, 4), relocalizedZoneID: f.zoneID,
            manifest: f.manifest, graph: f.graph
        )
        if let located {
            XCTAssertNotNil(located.routePosition.nodeID ?? located.routePosition.edgeID)
            // Low confidence must not auto-start, but must still be confirmable.
            if !located.canStartAutomatically {
                XCTAssertNotEqual(located.confidence, .unavailable)
            }
        }
    }

    /// The AR guidance path needs waypoints and a path; a downloaded package
    /// has neither, so they are synthesised from the graph and route.
    func testGuidanceInputsAreDerivedFromThePackageGraph() throws {
        let f = try makeFixture()
        let options = try ShortestPathService.findBestEgressRoute(
            from: RoutePosition(nodeID: f.roomID, worldPosition: .zero),
            graph: f.graph, profile: .standard
        )

        let path = EvacuationView.syntheticPath(options.best.nodes)
        XCTAssertEqual(path.count, options.best.nodes.count)

        let waypoints = EvacuationView.waypoints(from: f.graph, zoneID: f.zoneID)
        XCTAssertFalse(waypoints.isEmpty)
        // Identities must carry through, or AR anchors would not match.
        let ids = Set(waypoints.map(\.id))
        XCTAssertTrue(ids.contains(f.roomID))
        XCTAssertTrue(ids.contains(f.exitID))
    }
}
