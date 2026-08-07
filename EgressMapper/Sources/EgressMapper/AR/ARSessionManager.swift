import Foundation
import ARKit
import RealityKit
import Combine
import UIKit

enum ARSessionMode {
    case idle
    case mapping
    case relocalizing
    case navigating
}

/// What the camera feed itself is doing, independent of tracking quality.
///
/// Tracking can read "normal" while no frames are arriving at all, so this is
/// deliberately a separate axis: it answers "is the preview live?", which is
/// what the user is actually looking at.
enum CameraFeedState: Equatable {
    case idle
    /// Running and receiving frames.
    case active
    /// Running, but no frame has arrived for longer than the watchdog allows.
    case stalled(seconds: Int)
    /// ARKit reported an interruption (phone call, backgrounding, another app
    /// taking the camera). The map is still held in memory.
    case interrupted
    /// Re-running the session after an interruption, without resetting tracking.
    case recovering
    /// The session failed outright and cannot continue without user action.
    case failed(String)

    var isLive: Bool { self == .active }

    var label: String {
        switch self {
        case .idle: return "Camera idle"
        case .active: return "Camera feed active"
        case .stalled(let seconds): return "No camera frames for \(seconds)s"
        case .interrupted: return "Session interrupted"
        case .recovering: return "Recovering…"
        case .failed(let reason): return "Session failed — \(reason)"
        }
    }

    /// Whether the user should be shown an explicit recovery screen rather
    /// than a black rectangle.
    var needsRecoveryUI: Bool {
        switch self {
        case .stalled, .interrupted, .recovering, .failed: return true
        case .idle, .active: return false
        }
    }
}

enum ARSessionError: LocalizedError {
    case unsupported
    case cameraDenied
    case worldMapNotReady
    case worldMapSaveFailed(String)
    case noFrame

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "This iPhone does not support ARKit world tracking, which this prototype requires."
        case .cameraDenied:
            return "Camera access is denied. Enable it in Settings › Privacy › Camera."
        case .worldMapNotReady:
            return "The world map is not detailed enough to save yet. Keep walking and looking around."
        case .worldMapSaveFailed(let detail):
            return "Could not save the world map: \(detail)"
        case .noFrame:
            return "No camera frame is available yet."
        }
    }
}

/// Owns the ARView + ARSession for the whole app. Deliberately the only place
/// that touches ARKit session lifecycle, so world-map save/load stays correct.
@Observable
final class ARSessionManager: NSObject, ARSessionDelegate {

    // MARK: Published state
    private(set) var mode: ARSessionMode = .idle
    private(set) var status = TrackingStatus()
    private(set) var path = RoutePath()
    private(set) var waypoints: [Waypoint] = []
    private(set) var cameraPosition: SIMD3<Float> = .zero
    private(set) var cameraHeading: Float = 0
    private(set) var distanceTravelled: Double = 0
    private(set) var relocalizationSeconds: Int = 0
    private(set) var didRelocalize = false
    private(set) var isSaving = false
    var lastError: String?

    /// State of the camera feed, shown by the debug indicator and used to put
    /// an explicit recovery screen over the AR view instead of black.
    private(set) var cameraFeed: CameraFeedState = .idle
    /// Timestamp of the most recent frame ARKit delivered.
    private(set) var lastFrameTime: Date?
    /// Frames seen since the session last started. Diagnostic only.
    private(set) var frameCount: Int = 0

    /// Set once relocalization succeeds and saved anchors are matched.
    private(set) var restoredAnchorCount = 0

    /// Lowest detected horizontal plane — our best estimate of the floor.
    private(set) var estimatedFloorY: Float?

    /// Live controls for where AR geometry is drawn vertically.
    var heightMode: MarkerHeightMode = .floor {
        didSet { if heightMode != oldValue { refreshMarkers() } }
    }
    var heightOffset: Float = 0 {
        didSet { if heightOffset != oldValue { refreshMarkers() } }
    }

    /// Latest advisory OCR hit awaiting administrator confirmation.
    private(set) var lastRecognizedSign: RecognizedSign?
    var isOCREnabled = true {
        didSet { recognizer.isEnabled = isOCREnabled }
    }

    // MARK: AR
    let arView: ARView = {
        let v = ARView(frame: .zero)
        // We supply our own configuration; let RealityKit not override it.
        v.automaticallyConfigureSession = false
        v.environment.background = .cameraFeed()
        return v
    }()

    private var session: ARSession { arView.session }
    private var zone: MappingZone?
    private var markerAnchors: [UUID: AnchorEntity] = [:]
    private var lastRecordedPosition: SIMD3<Float>?
    private var lastRecordedHeading: Float?
    private var lastRecordedTime: TimeInterval?
    private var relocalizeStart: Date?
    private var currentMapping: ARFrame.WorldMappingStatus = .notAvailable
    private let store: ZoneFileStore
    private let recognizer = RoomSignRecognizer()
    /// The configuration currently running, kept so an interruption can be
    /// resumed with the *same* configuration and no tracking reset.
    private var activeConfiguration: ARWorldTrackingConfiguration?
    private var watchdog: Timer?
    /// Frames stop for a moment during normal operation; this is the point at
    /// which a gap stops being normal.
    static let frameStallSeconds: TimeInterval = 2.0
    /// Identifies this manager in the log, so two live sessions are obvious.
    let instanceID = UUID()

    init(store: ZoneFileStore = ZoneFileStore()) {
        self.store = store
        super.init()
        session.delegate = self
        DiagnosticsLog.shared.log("ARSessionManager \(shortID) created")
    }

    deinit {
        watchdog?.invalidate()
        DiagnosticsLog.shared.log("ARSessionManager \(instanceID.uuidString.prefix(8)) released")
    }

    var shortID: String { String(instanceID.uuidString.prefix(8)) }

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    // MARK: - Lifecycle

    private func makeConfiguration(initialMap: ARWorldMap? = nil) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.worldAlignment = .gravity
        config.isLightEstimationEnabled = true
        config.environmentTexturing = .automatic
        config.initialWorldMap = initialMap
        return config
    }

    func startMapping(zone: MappingZone) throws {
        guard Self.isSupported else { throw ARSessionError.unsupported }
        // Re-entering an already-running mapping session must not reset
        // tracking: that would throw away the map the user is recording.
        if mode == .mapping, self.zone?.id == zone.id, activeConfiguration != nil {
            DiagnosticsLog.shared.log("startMapping \(shortID) ignored — already mapping this zone")
            return
        }
        self.zone = zone
        mode = .mapping
        resetRecording()
        let config = makeConfiguration()
        activeConfiguration = config
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        beginFrameWatchdog()
        DiagnosticsLog.shared.log("startMapping \(shortID) zone=\(zone.id.uuidString.prefix(8))")
    }

    /// Loads a saved zone and attempts to relocalize against its world map.
    func startRelocalizing(zone: MappingZone, worldMap: ARWorldMap, waypoints: [Waypoint], path: RoutePath) throws {
        guard Self.isSupported else { throw ARSessionError.unsupported }
        self.zone = zone
        self.waypoints = waypoints
        self.path = path
        self.didRelocalize = false
        self.restoredAnchorCount = 0
        self.relocalizeStart = Date()
        self.relocalizationSeconds = 0
        mode = .relocalizing
        clearMarkers()
        let config = makeConfiguration(initialMap: worldMap)
        activeConfiguration = config
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        beginFrameWatchdog()
        DiagnosticsLog.shared.log("startRelocalizing \(shortID)")
    }

    func pause() {
        session.pause()
        cameraFeed = .idle
        stopFrameWatchdog()
    }

    func stop() {
        session.pause()
        stopFrameWatchdog()
        clearMarkers()
        recognizer.reset()
        lastRecognizedSign = nil
        mode = .idle
        cameraFeed = .idle
        activeConfiguration = nil
        DiagnosticsLog.shared.log("AR session \(shortID) stopped")
    }

    // MARK: - Camera liveness

    /// Frames are the only reliable evidence the preview is live. Tracking
    /// state is not: ARKit can keep reporting `.normal` after it has stopped
    /// delivering frames, which is exactly the frozen-preview case.
    private func beginFrameWatchdog() {
        stopFrameWatchdog()
        lastFrameTime = nil
        frameCount = 0
        cameraFeed = .active
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFrameLiveness() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopFrameWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func checkFrameLiveness() {
        guard mode != .idle else { return }
        // An interrupted or failed session has its own state; do not overwrite
        // it with a stall report.
        switch cameraFeed {
        case .interrupted, .recovering, .failed: return
        default: break
        }
        guard let last = lastFrameTime else { return }
        let gap = Date().timeIntervalSince(last)
        if gap >= Self.frameStallSeconds {
            let seconds = Int(gap)
            if cameraFeed != .stalled(seconds: seconds) {
                cameraFeed = .stalled(seconds: seconds)
                DiagnosticsLog.shared.log(
                    "\(shortID) camera stalled \(seconds)s (tracking=\(status.quality), frames=\(frameCount))"
                )
            }
        } else if cameraFeed != .active {
            cameraFeed = .active
        }
    }

    /// Re-runs the *same* configuration without resetting tracking, so an
    /// interrupted mapping walk keeps the map it has already built.
    func resumeAfterInterruption() {
        guard mode != .idle, let config = activeConfiguration else { return }
        cameraFeed = .recovering
        DiagnosticsLog.shared.log("\(shortID) resuming session, preserving the existing map")
        session.delegate = self
        session.run(config, options: [])
        beginFrameWatchdog()
        cameraFeed = .recovering
    }

    /// Called when the app returns to the foreground.
    func handleScenePhaseActive() {
        DiagnosticsLog.shared.log("\(shortID) scenePhase active, mode=\(mode)")
        guard mode != .idle else { return }
        if cameraFeed.needsRecoveryUI || lastFrameTime == nil {
            resumeAfterInterruption()
        }
    }

    func handleScenePhaseBackground() {
        DiagnosticsLog.shared.log("\(shortID) scenePhase background, mode=\(mode)")
        guard mode != .idle else { return }
        // ARKit suspends the session itself; record it so the return path
        // knows to re-run rather than assuming frames will resume.
        cameraFeed = .interrupted
        stopFrameWatchdog()
    }

    private func resetRecording() {
        path = RoutePath()
        waypoints = []
        distanceTravelled = 0
        lastRecordedPosition = nil
        lastRecordedHeading = nil
        lastRecordedTime = nil
        didRelocalize = false
        restoredAnchorCount = 0
        clearMarkers()
    }

    private func clearMarkers() {
        for (_, anchor) in markerAnchors { arView.scene.removeAnchor(anchor) }
        markerAnchors.removeAll()
    }

    // MARK: - ARSessionDelegate
    // ARKit delivers these on the main queue by default (delegateQueue == nil).

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lastFrameTime = Date()
        frameCount += 1
        if cameraFeed != .active { cameraFeed = .active }
        currentMapping = frame.worldMappingStatus
        let newStatus = TrackingStatus.interpret(
            tracking: frame.camera.trackingState,
            mapping: frame.worldMappingStatus
        )
        if newStatus != status { status = newStatus }

        let t = frame.camera.transform
        let position = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let heading = atan2(-t.columns.2.x, -t.columns.2.z)
        cameraPosition = position
        cameraHeading = heading

        if let start = relocalizeStart, mode == .relocalizing {
            let secs = Int(Date().timeIntervalSince(start))
            if secs != relocalizationSeconds { relocalizationSeconds = secs }
            // Relocalization is only trustworthy once ARKit reports normal
            // tracking again — .limited(.relocalizing) means it is still guessing.
            if newStatus.quality == .normal {
                didRelocalize = true
                relocalizeStart = nil
                mode = .navigating
                renderRestoredWaypoints()
            }
        }

        guard mode == .mapping, newStatus.quality == .normal else { return }
        recordIfNeeded(position: position, heading: heading, at: frame.timestamp)

        // Advisory only — never auto-creates a waypoint.
        recognizer.process(pixelBuffer: frame.capturedImage) { [weak self] sign in
            guard let self, self.mode == .mapping else { return }
            self.lastRecognizedSign = sign
        }
    }

    func dismissRecognizedSign() {
        lastRecognizedSign = nil
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        updateFloorEstimate(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        updateFloorEstimate(anchors)
    }

    /// Treats the lowest horizontal plane as the floor. Good enough indoors,
    /// and the user can nudge it with `heightOffset` if a low surface wins.
    private func updateFloorEstimate(_ anchors: [ARAnchor]) {
        var changed = false
        for plane in anchors.compactMap({ $0 as? ARPlaneAnchor }) where plane.alignment == .horizontal {
            let y = plane.transform.columns.3.y
            if estimatedFloorY == nil || y < estimatedFloorY! - 0.02 {
                estimatedFloorY = y
                changed = true
            }
        }
        if changed {
            DiagnosticsLog.shared.log("Floor estimate: \(estimatedFloorY.map { String($0) } ?? "nil")")
            refreshMarkers()
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        lastError = error.localizedDescription
        cameraFeed = .failed(error.localizedDescription)
        stopFrameWatchdog()
        DiagnosticsLog.shared.log("\(shortID) session failed: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        cameraFeed = .interrupted
        stopFrameWatchdog()
        DiagnosticsLog.shared.log("\(shortID) session interrupted (mode=\(mode))")
    }

    /// ARKit does not resume on its own in a way that keeps the preview live —
    /// the session must be re-run. Crucially with no options, so the map built
    /// so far is preserved.
    func sessionInterruptionEnded(_ session: ARSession) {
        lastError = nil
        DiagnosticsLog.shared.log("\(shortID) interruption ended")
        resumeAfterInterruption()
    }

    /// ARKit offers to relocalize after an interruption. Accepting it keeps the
    /// existing map and coordinate space, which is what a half-finished mapping
    /// walk needs; the alternative silently restarts the map.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }

    // MARK: - Path recording

    private func recordIfNeeded(position: SIMD3<Float>, heading: Float, at time: TimeInterval) {
        guard RoutePath.shouldRecord(
            newPosition: position,
            newHeading: heading,
            lastPosition: lastRecordedPosition,
            lastHeading: lastRecordedHeading,
            lastTime: lastRecordedTime,
            now: time
        ) else { return }

        if let previous = lastRecordedPosition {
            distanceTravelled += MapPoint(projecting: position).distance(to: MapPoint(projecting: previous))
        }
        path.append(position, at: time)
        lastRecordedPosition = position
        lastRecordedHeading = heading
        lastRecordedTime = time
    }

    // MARK: - Waypoints

    @discardableResult
    func addWaypoint(type: WaypointType, name: String) throws -> Waypoint {
        guard let zone else { throw ARSessionError.noFrame }
        guard let frame = session.currentFrame else { throw ARSessionError.noFrame }

        let transform = frame.camera.transform
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

        // Force a path point so pathIndex is meaningful for graph building.
        path.append(position, at: frame.timestamp)
        lastRecordedPosition = position
        lastRecordedHeading = atan2(-transform.columns.2.x, -transform.columns.2.z)
        lastRecordedTime = frame.timestamp

        let waypoint = Waypoint(
            zoneID: zone.id,
            name: name,
            type: type,
            anchorID: UUID(),
            transform: CodableTransform(transform),
            pathIndex: max(0, path.count - 1)
        )

        // Name encodes the waypoint id so anchors can be re-matched after the
        // world map is reloaded in a later session.
        let anchor = ARAnchor(name: "wp:\(waypoint.id.uuidString)", transform: transform)
        session.add(anchor: anchor)

        waypoints.append(waypoint)
        placeMarker(for: waypoint)
        return waypoint
    }

    func undoLastWaypoint() {
        guard let removed = waypoints.popLast() else { return }
        if let anchor = markerAnchors.removeValue(forKey: removed.id) {
            arView.scene.removeAnchor(anchor)
        }
        if let match = session.currentFrame?.anchors.first(where: { $0.name == "wp:\(removed.id.uuidString)" }) {
            session.remove(anchor: match)
        }
    }

    // MARK: - Markers

    private func placeMarker(for waypoint: Waypoint) {
        var position = waypoint.position
        position.y = ARRouteRenderer.placementY(
            capturedY: waypoint.position.y,
            groundY: estimatedFloorY,
            mode: heightMode,
            offset: heightOffset
        )
        let anchor = AnchorEntity(world: position)
        anchor.addChild(ARRouteRenderer.markerEntity(for: waypoint))
        arView.scene.addAnchor(anchor)
        markerAnchors[waypoint.id] = anchor
    }

    /// Re-places existing markers after a height setting or floor estimate change.
    private func refreshMarkers() {
        guard !markerAnchors.isEmpty else { return }
        clearMarkers()
        for waypoint in waypoints { placeMarker(for: waypoint) }
    }

    /// After a successful relocalization, redraw markers at their saved poses.
    private func renderRestoredWaypoints() {
        clearMarkers()
        for waypoint in waypoints { placeMarker(for: waypoint) }
        restoredAnchorCount = waypoints.count
    }

    // MARK: - Saving

    /// Captures world map + reference snapshot and writes the whole zone.
    /// Serialised via `isSaving` so two taps cannot race on getCurrentWorldMap.
    @MainActor
    func finishMapping(zone: MappingZone) async throws -> MappingZone {
        guard !isSaving else { throw ARSessionError.worldMapSaveFailed("A save is already in progress.") }
        guard status.canSave else { throw ARSessionError.worldMapNotReady }
        isSaving = true
        defer { isSaving = false }

        let map = try await currentWorldMap()
        let snapshot = await snapshotImage()

        // Serialising the world map and encoding the JPEG are the expensive
        // parts, and both are done off the main thread so the camera renderer
        // keeps running while the save happens.
        let waypointsCopy = waypoints
        let pathCopy = path
        let store = self.store

        var updated = zone
        updated.waypointCount = waypoints.count
        updated.pathLength = path.totalDistance
        updated.updatedAt = Date()
        // Set from what actually landed on disk, below — never asserted up
        // front, or a zone claims a world map it does not have.
        updated.hasWorldMap = false
        updated.hasReferenceImage = false

        let prepared = updated
        let result = try await Task.detached(priority: .userInitiated) { () -> (MappingZone, ZoneFileStore.CommitResult) in
            let mapData: Data
            do {
                mapData = try NSKeyedArchiver.archivedData(
                    withRootObject: map, requiringSecureCoding: true
                )
            } catch {
                throw ZoneFileStore.CommitError.write(
                    component: "AR world map", detail: error.localizedDescription
                )
            }
            let imageData = snapshot?.jpegData(compressionQuality: 0.7)

            var zone = prepared
            zone.hasWorldMap = true
            zone.hasReferenceImage = imageData != nil

            let commit = try store.commitZone(
                zone,
                waypoints: waypointsCopy,
                path: pathCopy,
                worldMap: mapData,
                referenceImage: imageData
            )
            return (zone, commit)
        }.value

        DiagnosticsLog.shared.log(
            "Saved zone \(result.1.zoneID.uuidString.prefix(8)) — \(result.1.waypointCount) waypoints, \(result.1.pathPoints) path points, worldMap=\(result.1.wroteWorldMap)"
        )
        return result.0
    }

    private func currentWorldMap() async throws -> ARWorldMap {
        try await withCheckedThrowingContinuation { continuation in
            session.getCurrentWorldMap { map, error in
                if let map {
                    continuation.resume(returning: map)
                } else {
                    continuation.resume(
                        throwing: ARSessionError.worldMapSaveFailed(
                            error?.localizedDescription ?? "unknown error"
                        )
                    )
                }
            }
        }
    }

    @MainActor
    private func snapshotImage() async -> UIImage? {
        await withCheckedContinuation { continuation in
            arView.snapshot(saveToHDR: false) { image in
                continuation.resume(returning: image)
            }
        }
    }
}
