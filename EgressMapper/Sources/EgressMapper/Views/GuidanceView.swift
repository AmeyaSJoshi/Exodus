import SwiftUI
import ARKit
import RealityKit

/// Relocalization + AR guidance. Deliberately refuses to draw arrows until
/// ARKit reports normal tracking, because a confidently wrong arrow is worse
/// than no arrow.
struct GuidanceView: View {
    let zone: MappingZone
    let route: [Waypoint]
    let path: RoutePath
    let allWaypoints: [Waypoint]
    var onExit: () -> Void

    @Environment(ZoneRepository.self) private var repository
    @State private var manager = ARSessionManager()
    @State private var engine: GuidanceEngine
    @State private var announcer = Announcer()
    @State private var update: GuidanceEngine.Update?
    @State private var errorMessage: String?
    @State private var didRenderRoute = false
    @State private var referenceImage: UIImage?
    @State private var lastTurnCueLeg = -1
    @State private var routeAnchors: [AnchorEntity] = []
    @AppStorage("voiceGuidanceEnabled") private var voiceEnabled = true

    init(
        zone: MappingZone,
        route: [Waypoint],
        path: RoutePath,
        allWaypoints: [Waypoint],
        onExit: @escaping () -> Void
    ) {
        self.zone = zone
        self.route = route
        self.path = path
        self.allWaypoints = allWaypoints
        self.onExit = onExit
        _engine = State(initialValue: GuidanceEngine(route: route))
    }

    private var relocalized: Bool { manager.didRelocalize }

    var body: some View {
        ZStack {
            ARViewContainer(manager: manager)
                .ignoresSafeArea()

            if !relocalized {
                relocalizationOverlay
            } else {
                guidanceOverlay
            }
        }
        .alert("Navigation", isPresented: .constant(errorMessage != nil)) {
            Button("Back") { errorMessage = nil; stopAndExit() }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: start)
        .onDisappear { announcer.stop(); manager.stop() }
        .onChange(of: manager.cameraPosition) { _, position in
            guard relocalized else { return }
            if !didRenderRoute {
                didRenderRoute = true
                redrawRoute()
                announcer.say("Route ready. \(route.first?.name ?? "") to \(route.last?.name ?? "").", force: true)
            }
            let next = engine.update(position: position)
            update = next
            handleCues(next)
        }
        .onChange(of: voiceEnabled) { _, enabled in
            announcer.isEnabled = enabled
            if !enabled { announcer.stopSpeaking() }
        }
        // Height settings changed, or ARKit found the floor — redraw in place.
        .onChange(of: manager.heightMode) { _, _ in redrawRoute() }
        .onChange(of: manager.heightOffset) { _, _ in redrawRoute() }
        .onChange(of: manager.estimatedFloorY) { _, _ in redrawRoute() }
    }

    private func redrawRoute() {
        guard didRenderRoute || relocalized else { return }
        for anchor in routeAnchors { manager.arView.scene.removeAnchor(anchor) }
        routeAnchors = ARRouteRenderer.renderRoute(
            route,
            in: manager.arView,
            groundY: manager.estimatedFloorY,
            mode: manager.heightMode,
            offset: manager.heightOffset
        )
    }

    // MARK: - Relocalization

    private var relocalizationOverlay: some View {
        VStack(spacing: 16) {
            Spacer()
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Relocalizing…")
                    .font(.headline)
                Text("Stand near where mapping began and pan the phone slowly across the same view.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if let referenceImage {
                    Image(uiImage: referenceImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottom) {
                            Text("Reference view from mapping")
                                .font(.caption2)
                                .padding(4)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(6)
                        }
                }

                Text(manager.status.trackingText)
                    .font(.caption)
                if let advice = manager.status.advice {
                    Text(advice).font(.caption2).foregroundStyle(.yellow)
                        .multilineTextAlignment(.center)
                }
                Text("\(manager.relocalizationSeconds)s elapsed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if manager.relocalizationSeconds > 25 {
                    Text("This environment may look different from when it was mapped — lighting, decorations or furniture changes all reduce the chance of a match.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))

            HStack(spacing: 12) {
                Button("Cancel") { stopAndExit() }
                    .buttonStyle(.bordered)
                Button("Retry") { restart() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
            Spacer()
        }
        .padding(20)
        .background(Color.black.opacity(0.35).ignoresSafeArea())
    }

    // MARK: - Guidance

    private var guidanceOverlay: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(update?.instruction ?? "Follow the arrows.")
                        .font(.headline)
                    Spacer()
                    Button {
                        voiceEnabled.toggle()
                    } label: {
                        Image(systemName: voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .foregroundStyle(voiceEnabled ? .green : .secondary)
                    }
                    .accessibilityLabel(voiceEnabled ? "Turn voice off" : "Turn voice on")
                    Button("Exit") { stopAndExit() }
                        .font(.caption)
                }
                if let update, !update.arrived {
                    HStack(spacing: 14) {
                        Label(String(format: "%.0f m to %@", update.distanceToNext, update.nextWaypoint?.name ?? "next"),
                              systemImage: "arrow.forward")
                        Label(String(format: "%.0f m total", update.remainingDistance), systemImage: "flag.checkered")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(manager.status.trackingText)
                    .font(.caption2)
                    .foregroundStyle(manager.status.isReliable ? .green : .orange)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

            if !manager.status.isReliable {
                Label(
                    manager.status.advice ?? "Tracking degraded — AR arrows hidden. Use the map below.",
                    systemImage: "eye.trianglebadge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            }

            Spacer()

            HeightControlView(manager: manager)
            DebugOverlayView(
                manager: manager,
                routeNode: update?.nextWaypoint?.name,
                distanceToNext: update?.distanceToNext
            )

            TopDownRouteView(
                path: path,
                waypoints: allWaypoints,
                currentPosition: MapPoint(projecting: manager.cameraPosition),
                currentHeading: manager.cameraHeading,
                highlightedRoute: route
            )
            .frame(height: 200)
        }
        .padding(12)
        // Hide precise AR geometry when ARKit is not confident.
        .onChange(of: manager.status.isReliable) { _, reliable in
            manager.arView.scene.anchors.forEach { $0.isEnabled = reliable }
        }
    }

    // MARK: - Actions

    private func start() {
        announcer.isEnabled = voiceEnabled
        announcer.configureAudioSession()
        referenceImage = repository.store.loadReferenceImage(zone.id)
        do {
            let map = try repository.store.loadWorldMap(zone.id)
            try manager.startRelocalizing(zone: zone, worldMap: map, waypoints: allWaypoints, path: path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restart() {
        didRenderRoute = false
        engine = GuidanceEngine(route: route)
        start()
    }

    private func stopAndExit() {
        announcer.stop()
        manager.stop()
        onExit()
    }

    private func handleCues(_ update: GuidanceEngine.Update) {
        if update.arrived {
            announcer.say(update.instruction)
            announcer.arrivalCue()
            return
        }
        // Haptic once per leg as the user closes on a turn.
        if update.distanceToNext < 3.5, lastTurnCueLeg != update.legIndex {
            lastTurnCueLeg = update.legIndex
            announcer.turnCue()
        }
        announcer.say(update.instruction)
    }
}
