import SwiftUI
import ARKit

struct MappingView: View {
    let zone: MappingZone
    var onFinish: () -> Void

    @Environment(ZoneRepository.self) private var repository
    @Environment(\.scenePhase) private var scenePhase
    @State private var manager = ARSessionManager()
    @State private var pendingType: WaypointType?
    @State private var showMap = true
    @State private var errorMessage: String?
    @State private var isFinishing = false
    @State private var hasLeft = false
    @State private var saveFailure: String?

    var body: some View {
        ZStack(alignment: .top) {
            ARViewContainer(manager: manager)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                statusOverlay
                if let sign = manager.lastRecognizedSign { ocrSuggestion(sign) }
                // Hidden, not merely covered: leaving it mounted meant the
                // whole recorded path was re-drawn behind the sheet on every
                // pose update while the user was typing.
                if showMap && pendingType == nil { mapOverlay }
                CameraDebugIndicator(manager: manager)
                HeightControlView(manager: manager)
                DebugOverlayView(manager: manager)
                Spacer()
                MappingControlsView(
                    canSave: manager.status.canSave && manager.waypoints.count >= 2,
                    saveBlockedReason: saveBlockedReason,
                    isFinishing: isFinishing,
                    onAdd: { pendingType = $0 },
                    onUndo: { manager.undoLastWaypoint() },
                    onFinish: { Task { await finish() } }
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .sheet(item: $pendingType) { type in
            AddWaypointSheet(type: type, suggestedIndex: nextIndex(for: type)) { name in
                addWaypoint(type: type, name: name)
            }
            .presentationDetents([.height(280)])
            .onAppear {
                Startup.firstUse("room-editor")
                // The AR session keeps running and recording; only the SwiftUI
                // updates behind the sheet stop, so the text field gets the
                // main thread to itself.
                manager.isUIPaused = true
                DiagnosticsLog.shared.log("Room editor presented over \(manager.shortID)")
            }
            .onDisappear {
                manager.isUIPaused = false
                // The moment the freeze is reported. What the manager logs
                // straight after this line says whether the session stopped or
                // only the renderer did.
                DiagnosticsLog.shared.log(
                    "Room editor dismissed — frames=\(manager.frameCount) lastRender=\(manager.secondsSinceRender.map { String(format: "%.2fs ago", $0) } ?? "never") feed=\(manager.cameraFeed.label)"
                )
            }
        }
        .alert("Mapping", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Save Failed", isPresented: .constant(saveFailure != nil)) {
            Button("Try Again") { saveFailure = nil; Task { await finish() } }
            Button("Keep Mapping", role: .cancel) { saveFailure = nil }
        } message: {
            Text(saveFailure ?? "")
        }
        .onAppear(perform: start)
        .onDisappear {
            // A sheet presented over the mapping view (adding a waypoint) can
            // fire onDisappear on the presenter. Stopping the session there
            // pauses the camera — a black preview that never comes back —
            // while the rest of the UI keeps working. Only stop when the
            // mapping flow is genuinely being left.
            guard isLeaving else {
                DiagnosticsLog.shared.log("MappingView disappeared with a sheet up — session kept alive")
                return
            }
            manager.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: manager.handleScenePhaseActive()
            case .background, .inactive: manager.handleScenePhaseBackground()
            @unknown default: break
            }
        }
        .overlay {
            // Never leave the user looking at a black rectangle with no
            // explanation: an unhealthy camera gets an explicit screen.
            if manager.cameraFeed.needsRecoveryUI {
                CameraRecoveryView(
                    state: manager.cameraFeed,
                    waypointCount: manager.waypoints.count,
                    onResume: { manager.resumeAfterInterruption() },
                    onClose: { hasLeft = true; manager.stop(); onFinish() }
                )
            }
        }
    }

    /// True only once the user has finished or closed, so a modal presentation
    /// is never mistaken for leaving the screen.
    private var isLeaving: Bool { hasLeft }

    // MARK: - Overlays

    private var statusOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(zone.displayTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    withAnimation { showMap.toggle() }
                } label: {
                    Image(systemName: showMap ? "map.fill" : "map")
                }
                Button("Close") { hasLeft = true; manager.stop(); onFinish() }
                    .font(.caption)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(manager.status.trackingText)
                Text("·").foregroundStyle(.secondary)
                Text(manager.status.mappingText)
            }
            .font(.caption)

            if let advice = manager.status.advice {
                Text(advice)
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }

            HStack(spacing: 14) {
                Label(String(format: "%.1f m", manager.distanceTravelled), systemImage: "ruler")
                Label("\(manager.path.count) pts", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                Label("\(manager.waypoints.count) wp", systemImage: "mappin.circle")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var mapOverlay: some View {
        TopDownRouteView(
            path: manager.path,
            waypoints: manager.waypoints,
            currentPosition: MapPoint(projecting: manager.cameraPosition),
            currentHeading: manager.cameraHeading
        )
        .frame(height: 190)
    }

    /// Advisory OCR hit. Never adds anything without an explicit tap.
    private func ocrSuggestion(_ sign: RecognizedSign) -> some View {
        HStack(spacing: 10) {
            Image(systemName: sign.type.symbolName)
                .foregroundStyle(sign.type.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(sign.text)” detected")
                    .font(.caption.weight(.semibold))
                Text("Add as \(sign.type.title)?")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add") {
                addWaypoint(type: sign.type, name: sign.suggestedName)
                manager.dismissRecognizedSign()
            }
            .font(.caption.weight(.semibold))
            Button {
                manager.dismissRecognizedSign()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusColor: Color {
        switch manager.status.quality {
        case .normal: return .green
        case .initializing, .relocalizing: return .yellow
        default: return .orange
        }
    }

    private var saveBlockedReason: String? {
        if manager.waypoints.count < 2 {
            return "Add at least two waypoints (for example a room and an exit) before saving."
        }
        return manager.status.saveBlockedReason
    }

    // MARK: - Actions

    private func start() {
        Startup.firstUse("mapping-open")
        do {
            try manager.startMapping(zone: zone)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func nextIndex(for type: WaypointType) -> Int {
        manager.waypoints.filter { $0.type == type }.count + 1
    }

    private func addWaypoint(type: WaypointType, name: String) {
        do {
            try manager.addWaypoint(type: type, name: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Only reports success once the zone has been written *and* read back, and
    /// only then leaves the screen — so a failed save keeps the live session and
    /// the recorded map, and the user can simply try again.
    private func finish() async {
        isFinishing = true
        defer { isFinishing = false }
        do {
            let saved = try await manager.finishMapping(zone: zone)
            await repository.refresh()
            guard repository.zones.contains(where: { $0.id == saved.id }) else {
                saveFailure = "The map was written but did not appear in Saved Maps. Nothing was overwritten — please try saving again."
                return
            }
            saveFailure = nil
            hasLeft = true
            manager.stop()
            onFinish()
        } catch let error as ZoneFileStore.CommitError {
            saveFailure = error.errorDescription
            DiagnosticsLog.shared.log("Save failed at component: \(error.component)")
        } catch {
            saveFailure = error.localizedDescription
        }
    }
}
