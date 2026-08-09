import SwiftUI
import ARKit
import RealityKit

/// Relocalization + AR guidance. Deliberately refuses to draw arrows until
/// ARKit reports normal tracking, because a confidently wrong arrow is worse
/// than no arrow.
struct GuidanceView: View {
    let zone: MappingZone
    let route: [RouteNode]
    let path: RoutePath
    let allWaypoints: [Waypoint]
    /// Segments of `route`, so a reported hazard can name the right one.
    var routeEdges: [RouteEdge] = []
    /// Supplied by Emergency mode so accessibility changes can reroute live.
    var rerouteContext: RerouteContext?
    /// Set when this zone is published, so administrator blocks reach AR.
    var liveService: SupabaseBuildingService?
    /// Explicit ARWorldMap bytes for callers whose map does not live in the
    /// local zone store — a downloaded building keeps its world map in the
    /// package cache, not under `Zones/<id>/`. Nil means "look in the store",
    /// which is what the mapper's own local flow wants.
    var worldMapData: Data?
    var onExit: () -> Void

    /// Everything needed to recompute a route without leaving navigation.
    /// The graph is re-read on each reroute so newly reported hazards apply.
    struct RerouteContext {
        var start: RoutePosition
    }

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
    @State private var activeRoute: [RouteNode] = []
    @State private var profile = NavigationProfile.standard
    @State private var showAccessibility = false
    @State private var rerouteNotice: String?
    @State private var activeEdges: [RouteEdge] = []
    @State private var showHazardReport = false
    @State private var showVoiceReport = false
    @State private var showRecovery = false
    @State private var wasReliable = true
    @AppStorage("voiceGuidanceEnabled") private var voiceEnabled = true

    init(
        zone: MappingZone,
        route: [RouteNode],
        path: RoutePath,
        allWaypoints: [Waypoint],
        routeEdges: [RouteEdge] = [],
        rerouteContext: RerouteContext? = nil,
        liveService: SupabaseBuildingService? = nil,
        worldMapData: Data? = nil,
        onExit: @escaping () -> Void
    ) {
        self.worldMapData = worldMapData
        self.zone = zone
        self.route = route
        self.path = path
        self.allWaypoints = allWaypoints
        self.routeEdges = routeEdges
        self.rerouteContext = rerouteContext
        self.liveService = liveService
        self.onExit = onExit
        _engine = State(initialValue: GuidanceEngine(route: route))
        _activeRoute = State(initialValue: route)
        _activeEdges = State(initialValue: routeEdges)
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
            // A route ruled out by this phone's own hazard reports must be
            // recoverable from here. Sending the user "Back" was the only
            // option, which left them unable to undo their own report.
            if hasOwnReports {
                Button("Clear My Reports") { clearOwnReports() }
            }
            Button("Back") { errorMessage = nil; stopAndExit() }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: start)
        .onAppear(perform: startLiveUpdates)
        .onDisappear {
            announcer.stop()
            manager.stop()
            Task { await liveService?.stopSubscription() }
        }
        .onChange(of: manager.cameraPosition) { _, position in
            guard relocalized else { return }
            if !didRenderRoute {
                didRenderRoute = true
                redrawRoute()
                announcer.say("Route ready. \(activeRoute.first?.name ?? "") to \(activeRoute.last?.name ?? "").", force: true)
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
        .onChange(of: manager.status.quality) { _, quality in
            let reliable = manager.status.isReliable
            // Precise AR geometry is hidden the moment ARKit stops trusting
            // its own pose — a frozen arrow in the wrong place is dangerous.
            manager.arView.scene.anchors.forEach { $0.isEnabled = reliable }
            if wasReliable && !reliable {
                announcer.haptic(.trackingLost)
                // Not while an alert is up: UIKit refuses the second
                // presentation and logs it once per frame forever.
                if quality == .notAvailable || quality == .relocalizing, errorMessage == nil {
                    showRecovery = true
                }
            }
            wasReliable = reliable
        }
        .confirmationDialog(
            "Tracking lost",
            isPresented: $showRecovery,
            titleVisibility: .visible
        ) {
            Button("Relocalize") { restart() }
            Button("Choose Location Manually") { stopAndExit() }
            Button("Keep using the 2D map", role: .cancel) {}
        } message: {
            Text("AR guidance is paused because the phone no longer knows where it is. The route map below is still accurate.")
        }
        .sheet(isPresented: $showHazardReport) {
            if let graph = repository.routableGraph(for: zone) {
                HazardReportView(
                    zone: zone,
                    graph: graph,
                    routeEdges: activeEdges,
                    currentLegIndex: engine.legIndex,
                    locationDescription: update?.nextNode.map { "Heading to \($0.name)" } ?? zone.displayTitle,
                    nextNodeName: update?.nextNode?.name
                ) { hazard, edgeID in
                    applyHazard(hazard, to: edgeID)
                }
            }
        }
        .sheet(isPresented: $showVoiceReport) {
            if let graph = repository.routableGraph(for: zone) {
                VoiceReportView(
                    zone: zone,
                    graph: graph,
                    routeEdges: activeEdges,
                    currentLegIndex: engine.legIndex
                ) { hazard, edgeID in
                    applyHazard(hazard, to: edgeID)
                } onAccessibility: { change in
                    profile = change.apply(to: profile)
                } onAlternativeExit: {
                    reroute(for: profile, reason: "Finding another exit.")
                } onClearReports: {
                    clearOwnReports()
                }
            }
        }
        .sheet(isPresented: $showAccessibility) {
            AccessibilitySheet(profile: $profile)
                .presentationDetents([.height(330)])
        }
        .onChange(of: profile) { _, updated in
            try? repository.store.saveProfile(updated)
            reroute(for: updated)
        }
    }

    /// Recomputes the best exit under a changed profile and swaps the AR
    /// geometry. Old anchors are removed before new ones are added.
    private func reroute(for profile: NavigationProfile, reason: String? = nil) {
        guard let context = rerouteContext else { return }
        guard let graph = currentEffectiveGraph() else {
            errorMessage = RoutingError.emptyGraph.localizedDescription
            return
        }
        do {
            let options = try ShortestPathService.findBestEgressRoute(
                from: context.start, graph: graph, profile: profile
            )
            activeRoute = options.best.nodes
            activeEdges = options.best.edges
            engine = GuidanceEngine(route: options.best.nodes)
            lastTurnCueLeg = -1
            redrawRoute()
            rerouteNotice = (reason.map { "\($0) " } ?? "") + "Rerouting to \(options.best.destination.name) — \(Int(options.best.totalDistanceMeters.rounded())) m."
            announcer.say("Your route has changed. Proceed to \(options.best.destination.name).", force: true)
            announcer.turnCue()
            DiagnosticsLog.shared.log("Rerouted: \(options.summary)")
        } catch {
            // Never silently ignore an accessibility preference.
            rerouteNotice = nil
            errorMessage = error.localizedDescription
            DiagnosticsLog.shared.log("Reroute failed: \(error.localizedDescription)")
        }
    }

    /// True when this phone has reported hazards on this zone.
    private var hasOwnReports: Bool {
        !repository.store.loadHazards(zone.id).hazards.isEmpty
    }

    /// Undoes every hazard this phone reported for this zone and re-routes.
    /// Only ever touches local reports — nothing an administrator published.
    private func clearOwnReports() {
        try? repository.store.clearHazards(zone.id)
        DiagnosticsLog.shared.log("Cleared this device's hazard reports for zone \(zone.id)")
        errorMessage = nil
        rerouteNotice = "Your reports were cleared. Looking for a route again."
        announcer.say("Reports cleared. Recalculating.", force: true)
        reroute(for: profile, reason: "Reports cleared.")
    }

    /// Persists the hazard next to (not inside) the permanent graph, then
    /// recomputes the best exit and swaps the AR geometry.
    private func applyHazard(_ hazard: RouteHazard, to edgeID: UUID) {
        var active = repository.store.loadHazards(zone.id)
        active.set(hazard, on: edgeID)
        try? repository.store.saveHazards(active, zoneID: zone.id)
        DiagnosticsLog.shared.log("Hazard \(hazard.type.rawValue) on edge \(edgeID)")
        announcer.arrivalCue()
        reroute(for: profile, reason: "\(hazard.type.displayName).")
    }

    /// Local graph with local hazards, then the administrator's live state on
    /// top. Neither layer mutates the stored graph.
    private func currentEffectiveGraph() -> BuildingGraph? {
        guard let base = repository.routableGraph(for: zone) else { return nil }
        guard let overlay = liveService?.overlay else { return base }
        return overlay.effectiveGraph(from: base)
    }

    private func redrawRoute() {
        guard didRenderRoute || relocalized else { return }

        // Tear the old route down completely before drawing the new one —
        // a stale arrow left pointing at a blocked corridor is dangerous.
        for anchor in routeAnchors { manager.arView.scene.removeAnchor(anchor) }
        routeAnchors.removeAll()

        let placed = ARRouteRenderer.renderRoute(
            activeRoute,
            in: manager.arView,
            groundY: manager.estimatedFloorY,
            mode: manager.heightMode,
            offset: manager.heightOffset
        )
        // Newly created anchors default to visible; respect the current
        // tracking state so a reroute cannot reveal arrows we do not trust.
        let reliable = manager.status.isReliable
        for anchor in placed { anchor.isEnabled = reliable }
        routeAnchors = placed
        DiagnosticsLog.shared.log("Rendered \(placed.count) route anchors (visible=\(reliable))")
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
                    Button {
                        callEmergencyServices()
                    } label: {
                        Image(systemName: "phone.fill").foregroundStyle(.red)
                    }
                    .accessibilityLabel("Call emergency services")
                    Button("End") { stopAndExit() }
                        .font(.caption)
                }
                if let update, !update.arrived {
                    HStack(spacing: 14) {
                        Label(String(format: "%.0f m to %@", update.distanceToNext, update.nextNode?.name ?? "next"),
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

            if let rerouteNotice {
                Label(rerouteNotice, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            }

            Spacer()

            if rerouteContext != nil {
                HStack(spacing: 8) {
                Button {
                    showHazardReport = true
                } label: {
                    Label("Report a Problem", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    showVoiceReport = true
                } label: {
                    Image(systemName: "mic.fill")
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .accessibilityLabel("Report a problem by voice")
                }
            }

            Button {
                showAccessibility = true
            } label: {
                Label("I Need an Accessible Route", systemImage: "figure.roll")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .opacity(rerouteContext == nil ? 0 : 1)
            .disabled(rerouteContext == nil)

            HeightControlView(manager: manager)
            DebugOverlayView(
                manager: manager,
                routeNode: update?.nextNode?.name,
                distanceToNext: update?.distanceToNext,
                estimate: rerouteContext.map {
                    LocationEstimate(
                        routePosition: $0.start,
                        nearestNodeName: activeRoute.first?.name,
                        distanceFromRouteMeters: 0,
                        confidence: .high
                    )
                },
                destinationExit: activeRoute.last?.name,
                activeHazardCount: repository.store.loadHazards(zone.id).hazards.count,
                profile: profile
            )

            TopDownRouteView(
                path: path,
                waypoints: allWaypoints,
                currentPosition: MapPoint(projecting: manager.cameraPosition),
                currentHeading: manager.cameraHeading,
                highlightedRoute: activeRoute
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
        profile = repository.store.loadProfile()
        announcer.configureAudioSession()
        referenceImage = repository.store.loadReferenceImage(zone.id)
        do {
            let map = try loadWorldMap()
            try manager.startRelocalizing(zone: zone, worldMap: map, waypoints: allWaypoints, path: path)
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticsLog.shared.log("Guidance world map unavailable: \(error.localizedDescription)")
        }
    }

    /// Supplied bytes win. A downloaded building's world map lives in the
    /// package cache, so looking only in the local zone store reported
    /// "no saved world map" for a map that was present all along.
    private func loadWorldMap() throws -> ARWorldMap {
        if let worldMapData {
            guard let map = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: ARWorldMap.self, from: worldMapData
            ) else { throw ZoneStoreError.worldMapUnarchiveFailed }
            DiagnosticsLog.shared.log(
                "Guidance decoded supplied world map (\(worldMapData.count) bytes)"
            )
            return map
        }
        let map = try repository.store.loadWorldMap(zone.id)
        DiagnosticsLog.shared.log("Guidance decoded world map from the local zone store")
        return map
    }

    private func restart() {
        didRenderRoute = false
        engine = GuidanceEngine(route: activeRoute)
        start()
    }

    /// Hands off to the system dialler — the app never places a call itself.
    private func callEmergencyServices() {
        guard let url = URL(string: "tel://911"), UIApplication.shared.canOpenURL(url) else {
            errorMessage = "This device cannot place phone calls."
            return
        }
        UIApplication.shared.open(url)
    }

    /// Administrator blocks arrive here and take the same path as any other
    /// reroute: old anchors are torn down before the replacement is drawn.
    private func startLiveUpdates() {
        guard let liveService, let buildingID = zone.remoteBuildingID else { return }
        liveService.onStateChanged = { changed in
            Task { @MainActor in
                guard let permanent = repository.routableGraph(for: zone) else { return }
                var name = "A route segment"
                if let changed, let edge = permanent.edge(changed.edgeStableID) {
                    let a = permanent.node(edge.fromNodeID)?.name ?? "here"
                    let b = permanent.node(edge.toNodeID)?.name ?? "the next point"
                    name = "\(a) → \(b)"
                }
                // Only disturb the user when their own route is affected.
                let affected = liveService.overlay.map { overlay in
                    activeEdges.contains { overlay.blockedEdgeIDs().contains($0.id) }
                } ?? false
                if affected || changed?.status == .available {
                    reroute(for: profile, reason: "\(name) was blocked by an administrator.")
                }
            }
        }
        Task { try? await liveService.subscribe(buildingID: buildingID) }
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
