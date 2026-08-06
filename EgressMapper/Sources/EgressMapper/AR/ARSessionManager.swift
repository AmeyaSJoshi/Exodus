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

    init(store: ZoneFileStore = ZoneFileStore()) {
        self.store = store
        super.init()
        session.delegate = self
    }

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
        self.zone = zone
        mode = .mapping
        resetRecording()
        session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
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
        session.run(makeConfiguration(initialMap: worldMap), options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        session.pause()
    }

    func stop() {
        session.pause()
        clearMarkers()
        recognizer.reset()
        lastRecognizedSign = nil
        mode = .idle
        DiagnosticsLog.shared.log("AR session stopped")
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
    }

    func sessionWasInterrupted(_ session: ARSession) {
        lastError = "AR session interrupted."
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        lastError = nil
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

        var updated = zone
        updated.waypointCount = waypoints.count
        updated.pathLength = path.totalDistance
        updated.hasWorldMap = true
        updated.hasReferenceImage = snapshot != nil
        updated.updatedAt = Date()

        let waypointsCopy = waypoints
        let pathCopy = path
        let store = self.store

        try await Task.detached(priority: .userInitiated) {
            try store.saveWorldMap(map, zoneID: updated.id)
            try store.saveWaypoints(waypointsCopy, zoneID: updated.id)
            try store.savePath(pathCopy, zoneID: updated.id)
            if let snapshot { try store.saveReferenceImage(snapshot, zoneID: updated.id) }
            try store.saveZone(updated)
        }.value

        return updated
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
