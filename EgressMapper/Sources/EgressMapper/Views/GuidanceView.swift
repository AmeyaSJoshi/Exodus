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
    @State private var rerouteDetail: String?
    @State private var activeEdges: [RouteEdge] = []
    @State private var showHazardReport = false
    @State private var showVoiceReport = false
    @State private var showRecovery = false
    @State private var showManualPicker = false
    /// Set when the occupant places themselves on the map by hand because
    /// relocalization could not find them. Guidance then runs from the 2D map:
    /// no AR arrows, because the phone still does not know its own pose.
    @State private var manualStart: RoutePosition?
    @State private var wasReliable = true
    /// `onAppear` fires again every time this view is rebuilt behind its
    /// presenter. Each `start()` restarted the AR session and threw away all
    /// relocalization progress, so a session that was seconds from a match kept
    /// being sent back to zero — which is why relocalization "never found you".
    @State private var didStart = false
    @State private var didSubscribe = false
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

    /// Guidance is on screen once ARKit has relocalized *or* the occupant has
    /// placed themselves manually. Manual placement used to drop them back to
    /// the setup screen, which is why it never appeared to work.
    private var guiding: Bool { relocalized || manualStart != nil }

    var body: some View {
        ZStack {
            ARViewContainer(manager: manager)
                .ignoresSafeArea()

            if !guiding {
                relocalizationOverlay
            } else {
                guidanceOverlay
            }
        }
        .alert("Navigation", isPresented: .presenting($errorMessage)) {
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
            Button("Choose Location Manually") { showManualPicker = true }
            Button("Keep using the 2D map", role: .cancel) {}
        } message: {
            Text("AR guidance is paused because the phone no longer knows where it is. The route map below is still accurate.")
        }
        .sheet(isPresented: $showManualPicker) {
            if let graph = repository.routableGraph(for: zone) {
                ManualLocationPickerView(
                    zone: zone, graph: graph, waypoints: allWaypoints, path: path
                ) { position, _ in
                    showManualPicker = false
                    applyManualStart(position)
                }
            }
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
                    reroute(for: profile, reason: "Finding another exit")
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
        guard let start = manualStart ?? rerouteContext?.start else { return }
        guard let graph = currentEffectiveGraph() else {
            errorMessage = RoutingError.emptyGraph.localizedDescription
            return
        }
        do {
            let options = try ShortestPathService.findBestEgressRoute(
                from: start, graph: graph, profile: profile
            )
            activeRoute = options.best.nodes
            activeEdges = options.best.edges
            engine = GuidanceEngine(route: options.best.nodes)
            lastTurnCueLeg = -1
            redrawRoute()
            rerouteNotice = reason ?? "Your route changed"
            rerouteDetail = "Rerouting to \(options.best.destination.name) — \(Int(options.best.totalDistanceMeters.rounded())) m"
            announcer.say("Your route has changed. Proceed to \(options.best.destination.name).", force: true)
            announcer.turnCue()
            DiagnosticsLog.shared.log("Rerouted: \(options.summary)")
        } catch {
            // Never silently ignore an accessibility preference.
            rerouteNotice = nil
            rerouteDetail = nil
            errorMessage = error.localizedDescription
            DiagnosticsLog.shared.log("Reroute failed: \(error.localizedDescription)")
        }
    }

    /// Commits a hand-placed position and puts guidance on screen. AR arrows
    /// stay hidden — the phone still has no pose — but the route, the step
    /// distances and the top-down map are all live from here.
    private func applyManualStart(_ position: RoutePosition) {
        manualStart = position
        lastTurnCueLeg = -1
        guard let graph = currentEffectiveGraph() else {
            errorMessage = RoutingError.emptyGraph.localizedDescription
            return
        }
        do {
            let options = try ShortestPathService.findBestEgressRoute(
                from: position, graph: graph, profile: profile
            )
            activeRoute = options.best.nodes
            activeEdges = options.best.edges
            engine = GuidanceEngine(route: options.best.nodes)
            rerouteNotice = "Location set manually"
            rerouteDetail = "Proceed to \(options.best.destination.name) — \(Int(options.best.totalDistanceMeters.rounded())) m"
            announcer.say(
                "Location set. Proceed to \(options.best.destination.name).", force: true
            )
            DiagnosticsLog.shared.log("Manual start accepted: \(options.summary)")
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticsLog.shared.log("Manual start failed: \(error.localizedDescription)")
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
        rerouteNotice = "Your reports were cleared"
        rerouteDetail = "Looking for a route again."
        announcer.say("Reports cleared. Recalculating.", force: true)
        reroute(for: profile, reason: "Reports cleared")
    }

    /// Persists the hazard next to (not inside) the permanent graph, then
    /// recomputes the best exit and swaps the AR geometry.
    private func applyHazard(_ hazard: RouteHazard, to edgeID: UUID) {
        var active = repository.store.loadHazards(zone.id)
        active.set(hazard, on: edgeID)
        try? repository.store.saveHazards(active, zoneID: zone.id)
        DiagnosticsLog.shared.log("Hazard \(hazard.type.rawValue) on edge \(edgeID)")
        announcer.arrivalCue()
        reroute(for: profile, reason: "\(hazard.type.displayName) reported")
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
        VStack(spacing: EG.Space.l) {
            Spacer()
            VStack(spacing: EG.Space.m) {
                EGLoadingState(
                    title: "Finding your location…",
                    detail: "Stand near where mapping began and pan the phone slowly across the same view."
                )

                if let referenceImage {
                    Image(uiImage: referenceImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 190)
                        .clipShape(RoundedRectangle(cornerRadius: EG.Radius.card))
                        .overlay(alignment: .bottom) {
                            Text("Reference view from mapping")
                                .font(.caption2)
                                .padding(EG.Space.xs)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(EG.Space.xs)
                        }
                        .accessibilityLabel("Reference photo taken when this area was mapped")
                }

                if let advice = manager.status.advice {
                    Text(advice)
                        .font(.subheadline)
                        .foregroundStyle(Color.egCaution)
                        .multilineTextAlignment(.center)
                }

                if manager.relocalizationSeconds > 25 {
                    Text("This space may look different from when it was mapped. Lighting, decorations and furniture all reduce the chance of a match.")
                        .font(.caption)
                        .foregroundStyle(Color.egCaution)
                        .multilineTextAlignment(.center)
                }

                #if DEBUG
                Text("\(manager.status.trackingText) · \(manager.relocalizationSeconds)s")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                #endif
            }
            .padding(EG.Space.l)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: EG.Radius.prominent))

            HStack(spacing: EG.Space.m) {
                Button("Cancel") { stopAndExit() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: EG.minTarget)
                Button("Try Again") { restart() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: EG.minTarget)
            }
            // Always reachable: relocalization is an optimisation, and someone
            // evacuating cannot be made to wait for it.
            Button {
                showManualPicker = true
            } label: {
                Label("Set My Location Manually", systemImage: "hand.tap")
            }
            .buttonStyle(EGPrimaryButtonStyle(tone: .neutral))
            Spacer()
        }
        .padding(EG.Space.l)
        .background(Color.black.opacity(0.45).ignoresSafeArea())
    }

    // MARK: - Guidance

    private var guidanceOverlay: some View {
        VStack(spacing: EG.Space.s) {
            instructionCard

            if !manager.status.isReliable && manualStart == nil {
                EGBanner(
                    title: EGStatus.trackingLimited.title,
                    detail: manager.status.advice ?? "AR arrows are hidden until the phone knows where it is. The map below is still accurate.",
                    tone: .caution,
                    symbol: EGStatus.trackingLimited.symbol
                )
                .modifier(EGTransition())
            }

            if let rerouteNotice {
                EGBanner(
                    title: rerouteNotice,
                    detail: rerouteDetail,
                    tone: .caution,
                    symbol: "arrow.triangle.branch",
                    onDismiss: { self.rerouteNotice = nil; self.rerouteDetail = nil }
                )
                .modifier(EGTransition())
            }

            Spacer()

            if rerouteContext != nil || manualStart != nil {
                HStack(spacing: EG.Space.s) {
                    Button {
                        showHazardReport = true
                    } label: {
                        Label("Report a Problem", systemImage: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(EGPrimaryButtonStyle(tone: .caution))

                    Button {
                        showVoiceReport = true
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: EG.minTarget + 10, height: EG.minTarget + 10)
                            .background(
                                Color.accentColor,
                                in: RoundedRectangle(cornerRadius: EG.Radius.control)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Report a problem by voice")
                }

                Button {
                    showAccessibility = true
                } label: {
                    Label("I Need an Accessible Route", systemImage: "figure.roll")
                }
                .buttonStyle(EGPrimaryButtonStyle(tone: .neutral))

                if !relocalized {
                    Button {
                        showManualPicker = true
                    } label: {
                        Label("Move My Location", systemImage: "hand.tap")
                    }
                    .buttonStyle(EGSecondaryButtonStyle())
                }
            }

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
            .clipShape(RoundedRectangle(cornerRadius: EG.Radius.card))
            .accessibilityLabel("Overhead map of your route")
        }
        .padding(EG.Space.m)
        .egAnimation(rerouteNotice)
        .egAnimation(manager.status.isReliable)
        .egAnimation(activeRoute.last?.id)
        // Hide precise AR geometry when ARKit is not confident.
        .onChange(of: manager.status.isReliable) { _, reliable in
            manager.arView.scene.anchors.forEach { $0.isEnabled = reliable }
        }
    }

    /// The one thing someone reads while moving: what to do next, how far, and
    /// where they are heading. Everything else on screen is subordinate.
    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: EG.Space.s) {
            HStack(alignment: .top, spacing: EG.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(destinationLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(instructionText)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                controlCluster
            }

            if let update, !update.arrived {
                HStack(spacing: EG.Space.l) {
                    Label(
                        String(format: "%.0f m to %@", update.distanceToNext, update.nextNode?.name ?? "next point"),
                        systemImage: "arrow.forward"
                    )
                    Label(
                        String(format: "%.0f m remaining", update.remainingDistance),
                        systemImage: "flag.checkered"
                    )
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else if update?.arrived == true {
                EGStatusBadge(status: .exitReached, compact: true)
            }

            EGStatusBadge(status: positionStatus, compact: true)
        }
        .padding(EG.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: EG.Radius.card))
    }

    /// Without a relocalized pose there is no live `update`, so name the next
    /// point from the route itself rather than telling someone to follow arrows
    /// that are deliberately not drawn.
    private var instructionText: String {
        if let update { return update.instruction }
        if manualStart != nil, activeRoute.count > 1 {
            return "Head to \(activeRoute[1].name)"
        }
        return "Follow the arrows."
    }

    private var destinationLabel: String {
        activeRoute.last.map { "Evacuating to \($0.name)" } ?? "Evacuating"
    }

    /// What the app actually knows about where the user is.
    private var positionStatus: EGStatus {
        if !relocalized && manualStart != nil {
            return .custom("Location set manually", "hand.tap.fill", .caution)
        }
        return manager.status.isReliable ? .locationFound : .trackingLimited
    }

    /// Icon-only controls: voice, emergency call, and ending navigation. Each
    /// carries its own VoiceOver label and a full-size tap target.
    private var controlCluster: some View {
        HStack(spacing: EG.Space.xs) {
            Button {
                voiceEnabled.toggle()
            } label: {
                Image(systemName: voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .foregroundStyle(voiceEnabled ? Color.egSafe : .secondary)
                    .frame(width: EG.minTarget, height: EG.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voiceEnabled ? "Turn voice guidance off" : "Turn voice guidance on")

            Button {
                callEmergencyServices()
            } label: {
                Image(systemName: "phone.fill")
                    .foregroundStyle(Color.egEmergency)
                    .frame(width: EG.minTarget, height: EG.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Call emergency services")

            Button("End") { stopAndExit() }
                .font(.subheadline.weight(.medium))
                .frame(minWidth: EG.minTarget, minHeight: EG.minTarget)
                .accessibilityLabel("End navigation")
        }
    }

    // MARK: - Actions

    private func start() {
        guard !didStart else { return }
        didStart = true
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
        didStart = false
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
        guard !didSubscribe else { return }
        guard let liveService, let buildingID = zone.remoteBuildingID else { return }
        didSubscribe = true
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
                    reroute(for: profile, reason: "\(name) unavailable")
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
