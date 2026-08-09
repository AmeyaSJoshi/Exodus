import SwiftUI

/// Emergency → "Which building are you in?" — organization buildings plus any
/// locally mapped zone. This is the normal product path; Live Backend
/// Diagnostics is not required for any of it.
struct EmergencyBuildingListView: View {
    @Environment(ZoneRepository.self) private var repository
    @Environment(StartupCoordinator.self) private var startup
    @Bindable var session: BackendSession

    /// Derived, not stored: signing in changes the catalogue, and a stored
    /// array captured before login would never refresh.
    private var entries: [BuildingEntry] {
        session.entries(localZones: repository.zones)
    }
    @State private var selectedRemote: CatalogBuilding?
    @State private var selectedZone: MappingZone?

    var body: some View {
        List {
            Section {
                Label(
                    "Follow official emergency instructions and posted evacuation procedures. This app is an aid, not an authority.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(Color.egCaution)
            }

            if !session.isSignedIn {
                BackendSignInView(session: session, title: "Sign in to see your buildings")
            }

            if let error = session.error, session.isSignedIn {
                Section {
                    EGBanner(
                        title: "Couldn't load your buildings",
                        detail: error,
                        tone: .caution
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    Button("Try Again") { startup.retry(session: session) }
                }
            }

            Section {
                if entries.isEmpty {
                    EGEmptyState(
                        title: session.isSignedIn ? "No buildings available" : "Sign in to continue",
                        message: session.isSignedIn
                            ? "Nothing has been published to your organization yet, and there are no maps on this device. Map a zone in Configure to navigate without a network."
                            : "Sign in above to load the buildings your organization has published.",
                        symbol: "building.2"
                    )
                    .listRowBackground(Color.clear)
                }
                ForEach(entries) { entry in
                    Button {
                        if let remote = entry.remote { selectedRemote = remote }
                        else { selectedZone = entry.localZone }
                    } label: {
                        BuildingRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Which building are you in?")
            } footer: {
                Text("Buildings marked Offline Available work without a network.")
            }
        }
        .navigationTitle("Emergency")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedRemote) { building in
            EvacuationView(session: session, building: building)
        }
        .navigationDestination(item: $selectedZone) { zone in
            RouteSetupView(zone: zone)
        }
        .task { startup.start(repository: repository, session: session) }
        .refreshable { await reload() }
        .onChange(of: session.isSignedIn) { _, signedIn in
            if signedIn { startup.authenticationChanged(session: session) }
        }
    }

    private func reload() async {
        startup.loadLocal(repository: repository, session: session)
        startup.refreshRemote(session: session, force: true)
    }
}

struct BuildingRow: View {
    let entry: BuildingEntry

    private var tint: Color {
        switch entry.availability {
        case .offlineAvailable, .publishedByYou: return .egSafe
        case .updateAvailable: return .egCaution
        case .downloadFailed: return .egEmergency
        case .downloading: return .accentColor
        default: return .secondary
        }
    }

    /// Availability is stated with a symbol as well as a colour.
    private var availabilitySymbol: String {
        switch entry.availability {
        case .offlineAvailable: return "arrow.down.circle.fill"
        case .publishedByYou: return "checkmark.seal.fill"
        case .updateAvailable: return "arrow.triangle.2.circlepath"
        case .downloadFailed: return "exclamationmark.triangle.fill"
        case .downloading: return "arrow.down.circle"
        case .localDraft: return "iphone"
        case .downloadRequired: return "icloud.and.arrow.down"
        }
    }

    var body: some View {
        HStack(spacing: EG.Space.m) {
            Image(systemName: "building.2.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color.egSurface, in: RoundedRectangle(cornerRadius: EG.Space.s))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.headline)
                Text(entry.subtitle).font(.subheadline).foregroundStyle(.secondary)
                Label(entry.availability.label, systemImage: availabilitySymbol)
                    .font(.caption)
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, EG.Space.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Loads a published building, applies live state before routing, lets the
/// occupant confirm where they are, then runs the evacuation. Uses the same
/// graph, overlay and `ShortestPathService` as every other flow.
struct EvacuationView: View {
    @Bindable var session: BackendSession
    let building: CatalogBuilding

    @State private var startNodeID: UUID?
    @State private var profile = NavigationProfile.standard
    @State private var options: ShortestPathService.EgressOptions?
    @State private var started = false
    @State private var banner: String?
    @State private var loadError: String?
    @State private var loading = true
    @State private var announcer = Announcer()
    /// The verified downloaded package for this building, when there is one.
    @State private var package: MapPackageManifest?
    @State private var packageGraph: BuildingGraph?
    /// Verified ARWorldMap bytes for this building, when the download actually
    /// contains one. Nil means routing data only — which must never block
    /// evacuation, only AR.
    @State private var worldMapData: Data?
    @State private var showLocalization = false
    @State private var locatedBy: BuildingLocalizationService.Method?
    /// The confirmed localization result, once the occupant accepts it.
    @State private var localized: BuildingLocalizationService.Result?
    /// The exit the occupant picked instead of the automatic choice.
    @State private var preferredExitID: UUID?
    /// True once guidance is actually on screen.
    @State private var navigating = false
    @State private var routeError: String?

    private var service: SupabaseBuildingService { session.service }

    /// The permanent graph, preferring the downloaded package so the building
    /// works with no network at all. The server copy is the fallback.
    private var permanentGraph: BuildingGraph? {
        packageGraph ?? service.graph
    }

    private var effectiveGraph: BuildingGraph? {
        guard let graph = permanentGraph else { return nil }
        guard let overlay = service.overlay else { return graph }
        return overlay.effectiveGraph(from: graph)
    }

    private var rooms: [RouteNode] {
        (effectiveGraph?.nodes ?? []).filter { $0.type != .exit && $0.type != .temporaryStart }
    }

    var body: some View {
        List {
            statusSection
            if loading {
                Section {
                    EGLoadingState(
                        title: "Loading building…",
                        detail: "Preparing the route map for \(building.name)."
                    )
                    .listRowBackground(Color.clear)
                }
            } else if effectiveGraph == nil {
                Section {
                    EGEmptyState(
                        title: "This building isn't available",
                        message: loadError ?? "No route map could be loaded for this building. Download it from Saved Maps, or choose a different building.",
                        symbol: "map",
                        tone: .caution
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                locationSection
                // The route preview appears as soon as a start point exists,
                // so there is always a visible next action.
                if startNodeID != nil { readySection; mapSection }
            }
        }
        .navigationTitle(building.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { Task { await service.stopSubscription() } }
        .fullScreenCover(isPresented: $showLocalization) {
            if let package, let graph = permanentGraph {
                BuildingLocalizationView(
                    manifest: package,
                    graph: graph,
                    cache: session.packages,
                    onLocated: { result in
                        showLocalization = false
                        confirmLocalization(result)
                    },
                    onCancel: { showLocalization = false }
                )
            }
        }
        .fullScreenCover(isPresented: $navigating) {
            guidanceDestination
        }
        .egAnimation(options?.best.destination.id)
        .egAnimation(banner)
        .onChange(of: startNodeID) { _, _ in recompute(announce: false) }
        .onChange(of: profile) { _, _ in recompute(announce: false) }
        .onChange(of: preferredExitID) { _, _ in recompute(announce: false) }
    }

    private var statusSection: some View {
        Section {
            EGConnectionRow(connection: service.connection, usingCache: service.usingCache)
                .egAnimation(service.connection)

            if package != nil {
                Label("Available offline", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.egSafe)
                if isRoutingDataOnly {
                    Label(
                        "Camera positioning unavailable — this map has routing data only.",
                        systemImage: "arkit"
                    )
                    .font(.caption).foregroundStyle(Color.egCaution)
                }
            }
            if let loadError, effectiveGraph != nil {
                Label(loadError, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Color.egCaution)
            }
            #if DEBUG
            LabeledContent("Revision", value: "\(service.revision)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let package {
                LabeledContent("Package", value: "v\(package.version) · \(package.nodes.count) points")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            #endif
        }
    }

    /// Camera localization needs a downloaded package with at least one
    /// ARWorldMap — never offered when it could not possibly work.
    private var canLocalizeWithCamera: Bool {
        guard let package, worldMapData != nil, ARSessionManager.isSupported else { return false }
        return !BuildingLocalizationService.relocalizableZones(in: package).isEmpty
    }

    /// The package downloaded fine, it just has no AR map. Worth saying so:
    /// the user would otherwise wonder why the camera option is missing.
    private var isRoutingDataOnly: Bool {
        package != nil && worldMapData == nil
    }

    private var locationSection: some View {
        Section {
            if canLocalizeWithCamera {
                Button {
                    showLocalization = true
                } label: {
                    Label("Find Me with the Camera", systemImage: "location.magnifyingglass")
                }
                .buttonStyle(EGPrimaryButtonStyle(tone: .neutral))
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }

            Picker("I am at", selection: $startNodeID) {
                Text("Select a room…").tag(UUID?.none)
                ForEach(rooms) { node in
                    Text(node.name).tag(UUID?.some(node.id))
                }
            }
            Toggle("Avoid stairs", isOn: $profile.avoidStairs)
            Toggle("Wheelchair accessible only", isOn: $profile.requireWheelchairAccessible)

            if let localized {
                LabeledContent("Detected", value: BuildingLocalizationService.describe(localized, manifest: package ?? placeholderManifest))
                    .font(.caption)
                LabeledContent("Confidence", value: localized.confidence.displayName)
                    .font(.caption)
                    .foregroundStyle(localized.canStartAutomatically ? Color.secondary : Color.orange)
            }
        } header: {
            Text("Where are you?")
        } footer: {
            if canLocalizeWithCamera {
                Text("Point the camera around you to be found automatically, or pick the nearest room.")
            } else if package == nil {
                Text("Download this building from Saved Maps to enable camera localization. Picking a room works either way.")
            } else if isRoutingDataOnly {
                Text("AR localization is unavailable for this map — it contains routing data only. Select your room manually; evacuation guidance still works.")
            } else {
                Text("This device cannot use camera relocalization. Pick the nearest room.")
            }
        }
    }

    /// Everything between "we know where you are" and "guidance is running".
    /// There is always exactly one obvious next action here.
    @ViewBuilder
    private var readySection: some View {
        Section {
            if let banner {
                EGBanner(
                    title: banner,
                    tone: .caution,
                    symbol: "arrow.triangle.branch",
                    onDismiss: { self.banner = nil }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .modifier(EGTransition())
            }
            if let best = options?.best {
                VStack(alignment: .leading, spacing: EG.Space.s) {
                    EGStatusBadge(status: .routeReady, compact: true)
                    Text(best.destination.name)
                        .font(.title2.weight(.bold))
                    Text("\(Int(best.totalDistanceMeters.rounded())) m · \(best.nodes.count - 1) steps")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(best.nodes.map(\.name).joined(separator: " → "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, EG.Space.xs)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Route ready to \(best.destination.name), \(Int(best.totalDistanceMeters.rounded())) meters"
                )

                if best.isRefugeFallback {
                    Label(
                        "No exit is reachable — routing to an area of refuge.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(Color.egCaution)
                }
                if let locatedBy {
                    Label(locatedBy.displayName, systemImage: "location.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #if DEBUG
                if let summary = options?.summary {
                    Text(summary).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                #endif

                Button {
                    start()
                } label: {
                    Label("Start Evacuation", systemImage: "figure.run")
                }
                .buttonStyle(EGPrimaryButtonStyle(tone: .critical))
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .disabled(!canStart)

                if let alternatives = options?.alternatives, !alternatives.isEmpty {
                    Menu("Choose another safe exit") {
                        ForEach(alternatives, id: \.destination.id) { route in
                            Button("\(route.destination.name) — \(Int(route.totalDistanceMeters.rounded())) m") {
                                preferredExitID = route.destination.id
                            }
                        }
                        if preferredExitID != nil {
                            Button("Use the safest exit") { preferredExitID = nil }
                        }
                    }
                    .font(.subheadline)
                }
            } else {
                // Never leave a located occupant with no next action: say what
                // went wrong and what they can do instead.
                EGEmptyState(
                    title: "No safe route from here",
                    message: routeError ?? loadError
                        ?? "Every route out of this location is currently blocked or ruled out by your accessibility settings. Try another starting room.",
                    symbol: "exclamationmark.triangle.fill",
                    tone: .critical,
                    actionTitle: "Choose Another Room",
                    action: { localized = nil; startNodeID = nil }
                )
                .listRowBackground(Color.clear)
            }
        } header: {
            Text("Your route out")
        }
    }

    /// Every precondition the evacuation genuinely needs. Only this button is
    /// gated — nothing else on the screen is disabled while it is not met.
    private var canStart: Bool {
        effectiveGraph != nil
            && startNodeID != nil
            && options?.best != nil
            && service.overlay != nil
    }

    /// Stands in when a building has no downloaded package, purely so the
    /// location description has something to name.
    private var placeholderManifest: MapPackageManifest {
        MapPackageManifest(
            schemaVersion: MapPackageManifest.currentSchemaVersion,
            buildingID: building.id, buildingName: building.name,
            mapVersionID: building.activeMapVersionID ?? building.id,
            version: building.version ?? 0, defaultFloorID: "default",
            createdAt: Date(), zones: [], nodes: [], edges: [], artifacts: []
        )
    }

    /// AR guidance when this building has a real world map on the device and
    /// the phone supports it; the 2D route otherwise. One routing service
    /// feeds both.
    @ViewBuilder
    private var guidanceDestination: some View {
        if let graph = effectiveGraph, let best = options?.best, let startNodeID {
            let zone = MappingZone(
                id: package?.zones.first?.id ?? building.id,
                campus: building.address ?? "",
                building: building.name,
                floor: package?.defaultFloorID ?? "default",
                zoneName: building.name
            )
            // AR only when a decodable world map is actually on the device.
            // Everything else falls through to 2D — evacuation must not depend
            // on AR being available.
            if let worldMapData, ARSessionManager.isSupported {
                GuidanceView(
                    zone: zone,
                    route: best.nodes,
                    path: Self.syntheticPath(best.nodes),
                    allWaypoints: Self.waypoints(from: graph, zoneID: zone.id),
                    routeEdges: best.edges,
                    rerouteContext: .init(
                        start: RoutePosition(
                            nodeID: startNodeID,
                            worldPosition: graph.node(startNodeID)?.worldPosition ?? .zero
                        )
                    ),
                    liveService: service,
                    worldMapData: worldMapData
                ) { navigating = false }
            } else {
                TwoDGuidanceView(
                    buildingName: building.name,
                    graph: graph,
                    route: best,
                    startNodeID: startNodeID,
                    banner: banner,
                    connection: service.connection
                ) { navigating = false }
            }
        }
    }

    /// The package carries node positions but no recorded walk, so the route
    /// itself stands in for the path the top-down map draws.
    static func syntheticPath(_ nodes: [RouteNode]) -> RoutePath {
        var path = RoutePath()
        for (index, node) in nodes.enumerated() {
            path.append(node.worldPosition, at: TimeInterval(index))
        }
        return path
    }

    static func waypoints(from graph: BuildingGraph, zoneID: UUID) -> [Waypoint] {
        graph.nodes.compactMap { node in
            // hallwayPoint and temporaryStart have no waypoint equivalent and
            // are not things the user navigates *to*.
            guard let type = WaypointType(rawValue: node.type.rawValue) else { return nil }
            return Waypoint(
                id: node.id, zoneID: zoneID, name: node.name, type: type,
                anchorID: node.id, transform: node.position, pathIndex: 0
            )
        }
    }

    private var mapSection: some View {
        Section {
            LiveGraphMapView(
                graph: effectiveGraph ?? BuildingGraph(zoneID: building.id, nodes: [], edges: []),
                route: options?.best.nodes ?? [],
                startNodeID: startNodeID
            )
            .frame(height: 240)
            .listRowInsets(EdgeInsets())
        }
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        defer { loading = false }
        profile = NavigationProfile.standard

        // The downloaded package first: it is verified, it carries the AR world
        // map, and it needs no network. Only if there is none do we depend on
        // the server for the graph.
        if let cached = session.cachedPackage(for: building.id) {
            package = cached
            packageGraph = MapPackageBuilder.graph(from: cached)
            // Checked once, from the bytes on disk. The manifest promising a
            // world map is not the same as the file being present and intact.
            worldMapData = session.packages.worldMapData(buildingID: building.id)
            DiagnosticsLog.shared.log(
                "Emergency loaded \(building.name) v\(cached.version): \(cached.nodes.count) nodes, worldMap=\(worldMapData?.count ?? 0) bytes"
            )
        }

        let remote = RemoteBuilding(
            id: building.id, name: building.name,
            address: building.address, activeMapVersionID: building.activeMapVersionID
        )
        do {
            if packageGraph == nil {
                try await service.loadGraph(for: remote)
            }
            // Live state is applied *before* any route is calculated.
            service.onStateChanged = { changed in
                Task { @MainActor in handleLiveChange(changed) }
            }
            try await service.subscribe(buildingID: building.id)
            startNodeID = rooms.first(where: { $0.type == .room })?.id ?? rooms.first?.id
        } catch {
            // A downloaded building still routes with no connection; say so
            // rather than reporting it as unavailable.
            if packageGraph != nil {
                loadError = "Offline — using the downloaded map. Live closures are unavailable."
                startNodeID = rooms.first(where: { $0.type == .room })?.id ?? rooms.first?.id
            } else {
                loadError = error.localizedDescription
            }
        }
    }

    /// Commits a localization result to the evacuation: snap to the graph,
    /// pick an exit, and put a live route on screen. Nothing here starts
    /// guidance — the occupant still presses Start Evacuation.
    private func confirmLocalization(_ result: BuildingLocalizationService.Result) {
        localized = result
        locatedBy = result.method
        routeError = nil

        // The localization search runs against the same graph this view routes
        // on, so a snapped node is expected to resolve. If it does not, say so
        // rather than silently falling back to a stale selection.
        if let nodeID = result.routePosition.nodeID, effectiveGraph?.node(nodeID) != nil {
            startNodeID = nodeID
        } else if let edgeID = result.routePosition.edgeID, effectiveGraph?.edge(edgeID) != nil {
            // Mid-hallway: route from the nearest end of that segment.
            startNodeID = effectiveGraph?.edge(edgeID)?.fromNodeID
        } else {
            routeError = "Your location was recognised but is not on this building's route graph. Choose the nearest room instead."
            startNodeID = nil
            return
        }
        recompute(announce: false)
        DiagnosticsLog.shared.log(
            "Localized via \(result.method.rawValue), start=\(startNodeID?.uuidString.prefix(8) ?? "-"), exit=\(options?.best.destination.name ?? "none")"
        )
    }

    /// Opens guidance. Every precondition was already checked by `canStart`.
    private func start() {
        guard canStart else { return }
        started = true
        navigating = true
        announcer.say(
            "Evacuating to \(options?.best.destination.name ?? "the nearest exit").", force: true
        )
        DiagnosticsLog.shared.log("Evacuation started -> \(options?.best.destination.name ?? "?")")
    }

    private func recompute(announce: Bool, changedName: String? = nil) {
        guard let graph = effectiveGraph, let startNodeID,
              let node = graph.node(startNodeID) else { options = nil; return }
        let previous = options?.best.destination.id
        do {
            var result = try ShortestPathService.findBestEgressRoute(
                from: RoutePosition(nodeID: node.id, worldPosition: node.worldPosition),
                graph: graph, profile: profile
            )
            // Honour an explicitly chosen exit, but only while it is still
            // reachable — a live closure must be able to override the choice.
            if let preferredExitID,
               let chosen = ([result.best] + result.alternatives)
                   .first(where: { $0.destination.id == preferredExitID }) {
                let rest = ([result.best] + result.alternatives).filter { $0.destination.id != preferredExitID }
                result = ShortestPathService.EgressOptions(
                    best: chosen, alternatives: rest, unreachable: result.unreachable
                )
            }
            options = result
            routeError = nil
            loadError = nil
            if announce, previous != result.best.destination.id {
                let message = LiveStateOverlay.changeMessage(
                    edgeName: changedName ?? "Your route",
                    status: .blocked,
                    newExit: result.best.destination.name
                )
                banner = message
                announcer.say(message, force: true)
                announcer.haptic(.routeChanged)
            } else if announce {
                banner = "\(changedName ?? "Building state") changed. Route unaffected."
            }
        } catch {
            options = nil
            routeError = error.localizedDescription
            if announce { announcer.say(error.localizedDescription, force: true) }
        }
    }

    private func handleLiveChange(_ changed: LiveEdgeState?) {
        // Edge stable ids are preserved through publication, so a live closure
        // names the same edge whether the graph came from the package or the
        // server.
        guard started, let permanent = permanentGraph else { return }
        var name: String?
        if let changed, let edge = permanent.edge(changed.edgeStableID) {
            let a = permanent.node(edge.fromNodeID)?.name ?? "A segment"
            let b = permanent.node(edge.toNodeID)?.name ?? "the next point"
            name = "\(a) → \(b)"
        }
        recompute(announce: changed != nil, changedName: name)
        if changed?.status == .available {
            banner = "\(name ?? "A segment") is open again."
        }
    }
}
