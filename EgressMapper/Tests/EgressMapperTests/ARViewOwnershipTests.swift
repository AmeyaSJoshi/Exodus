import XCTest
import RealityKit
@testable import EgressMapper

/// `ARSessionManager` used to build its `ARView` in an eagerly initialised
/// stored property. SwiftUI re-runs the initializer expression of
/// `@State private var manager = ARSessionManager()` every time the view struct
/// is created and discards the surplus instances — so every discarded manager
/// paid for a Metal renderer, a RealityKit scene and an ARSession it never
/// used. Construction must be free; the ARView appears only when something
/// actually shows it.
@MainActor
final class ARViewOwnershipTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("egress-arview-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager() -> ARSessionManager {
        ARSessionManager(store: ZoneFileStore(root: root))
    }

    // MARK: - Construction is free

    func testConstructingAManagerDoesNotBuildAnARView() {
        let manager = makeManager()
        XCTAssertFalse(
            manager.hasARView,
            "a manager SwiftUI is about to throw away must not allocate an ARView"
        )
        XCTAssertEqual(manager.mode, .idle)
    }

    /// The exact SwiftUI pattern: several managers constructed, one kept.
    func testDiscardedManagersCostNothing() {
        var managers: [ARSessionManager] = []
        for _ in 0..<10 { managers.append(makeManager()) }
        XCTAssertTrue(
            managers.allSatisfy { !$0.hasARView },
            "ten constructions must produce zero ARViews"
        )
    }

    func testStoppingAManagerThatNeverShowedARDoesNotBuildOne() {
        let manager = makeManager()
        manager.stop()
        manager.pause()
        XCTAssertFalse(
            manager.hasARView,
            "tearing down must never allocate the thing it is tearing down"
        )
    }

    func testScenePhaseChangesOnAnIdleManagerDoNotBuildAnARView() {
        let manager = makeManager()
        manager.handleScenePhaseBackground()
        manager.handleScenePhaseActive()
        manager.resumeAfterInterruption()
        manager.viewAttachedToWindow()
        XCTAssertFalse(manager.hasARView)
    }

    // MARK: - Identity is stable

    /// The Room editor edits metadata. It must not disturb who owns the
    /// session: the same ARView and the same ARSession have to survive it.
    func testARViewAndSessionIdentityAreStableAcrossRepeatedAccess() throws {
        try XCTSkipUnless(ARSessionManager.isSupported, "ARView needs a device")
        let manager = makeManager()

        let first = manager.arView
        let firstSession = first.session
        // Standing in for a sheet presentation cycle: the view is read again
        // on every body evaluation while the Room editor comes and goes.
        for _ in 0..<5 { _ = manager.arView }
        let second = manager.arView

        XCTAssertTrue(first === second, "the ARView must never be rebuilt")
        XCTAssertTrue(
            firstSession === second.session,
            "rebuilding the session would discard the map being recorded"
        )
        XCTAssertEqual(ObjectIdentifier(first), ObjectIdentifier(second))
    }

    func testTheContainerHandsBackTheManagersOwnARView() throws {
        try XCTSkipUnless(ARSessionManager.isSupported, "ARView needs a device")
        let manager = makeManager()
        let container = ARViewContainer(manager: manager)
        let hosted = container.manager.arView
        XCTAssertTrue(hosted === manager.arView)
    }

    // MARK: - Distinguishing a stopped session from a parked renderer

    func testAFreshManagerHasNeverRendered() {
        let manager = makeManager()
        XCTAssertNil(manager.lastRenderTime)
        XCTAssertNil(manager.secondsSinceRender)
        XCTAssertNil(manager.lastFrameTime)
        XCTAssertEqual(manager.frameCount, 0)
    }

    /// Every manager is separately identifiable in the log, so two live
    /// sessions — the thing that must never happen — are obvious.
    func testManagersAreDistinguishableInLogs() {
        let a = makeManager()
        let b = makeManager()
        XCTAssertNotEqual(a.instanceID, b.instanceID)
        XCTAssertNotEqual(a.shortID, b.shortID)
    }
}

/// Home must not touch ARKit, decode packages, or read anything large.
@MainActor
final class HomeStartupCostTests: XCTestCase {

    override func tearDown() {
        DeviceCapabilities.probe = { true }
        super.tearDown()
    }

    func testHomeDoesNotProbeARKitUntilAskedTo() {
        let probed = OSAllocatedUnfairLockBox(false)
        DeviceCapabilities.probe = { probed.set(true); return true }

        // Constructing the capability object is what the app root does.
        _ = DeviceCapabilities()
        XCTAssertFalse(
            probed.value,
            "ARKit must not be initialised merely because the app launched"
        )
    }

    /// A launch scan reads `zone.json` only. Anything that scaled with what the
    /// user had recorded would make the first tap slower the more they mapped.
    func testTheLaunchScanReadsNoLargeFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("egress-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ZoneFileStore(root: root)

        let zone = MappingZone(campus: "M", building: "Wade", floor: "2", zoneName: "East")
        try store.saveZone(zone)
        // A large, undecodable world map and a reference image alongside it.
        try Data(repeating: 0xFF, count: 4_000_000).write(
            to: store.url(zone.id, "worldmap.arexperience")
        )
        try Data(repeating: 0xAA, count: 2_000_000).write(to: store.url(zone.id, "reference.jpg"))

        let started = Date()
        let result = store.scanZones()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.zones.count, 1)
        XCTAssertLessThan(
            elapsed, 0.25,
            "the scan touched something large; it must read metadata only"
        )
    }

    func testPackageCacheVersionLookupDoesNotDecodeArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("egress-pkg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MapPackageCache(root: root)

        let zone = MappingZone(campus: "M", building: "Wade", floor: "2", zoneName: "East")
        let node = RouteNode(
            name: "Room 214", type: .room, position: .identity, zoneID: zone.id
        )
        let big = Data(repeating: 0xCD, count: 3_000_000)
        let pending = PendingArtifact(
            kind: .worldmap, zoneID: zone.id, fileName: "worldmap.arexperience", data: big
        )
        let manifest = try MapPackageBuilder.build(
            zone: zone,
            graph: BuildingGraph(zoneID: zone.id, nodes: [node], edges: []),
            buildingID: UUID(), buildingName: "Wade", mapVersionID: UUID(), version: 1,
            artifacts: [pending]
        )
        try cache.store(
            manifest: manifest, files: [manifest.artifact(pending.id)!.storagePath: big]
        )

        // What Saved Maps calls on every appearance.
        let started = Date()
        let versions = cache.allCachedVersions()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(versions[manifest.buildingID], 1)
        XCTAssertLessThan(
            elapsed, 0.25,
            "listing cached versions must not hash or read the artifacts"
        )
    }
}
