import SwiftUI
import ARKit

struct MappingView: View {
    let zone: MappingZone
    var onFinish: () -> Void

    @Environment(ZoneRepository.self) private var repository
    @State private var manager = ARSessionManager()
    @State private var pendingType: WaypointType?
    @State private var showMap = true
    @State private var errorMessage: String?
    @State private var isFinishing = false

    var body: some View {
        ZStack(alignment: .top) {
            ARViewContainer(manager: manager)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                statusOverlay
                if let sign = manager.lastRecognizedSign { ocrSuggestion(sign) }
                if showMap { mapOverlay }
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
        }
        .alert("Mapping", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: start)
        .onDisappear { manager.stop() }
    }

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
                Button("Close") { manager.stop(); onFinish() }
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

    private func finish() async {
        isFinishing = true
        defer { isFinishing = false }
        do {
            let saved = try await manager.finishMapping(zone: zone)
            await repository.upsert(saved)
            manager.stop()
            onFinish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
