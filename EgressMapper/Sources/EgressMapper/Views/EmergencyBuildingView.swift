import SwiftUI

/// Emergency → "Which building are you in?" — organization buildings plus any
/// locally mapped zone. This is the normal product path; Live Backend
/// Diagnostics is not required for any of it.
struct EmergencyBuildingListView: View {
    @Environment(ZoneRepository.self) private var repository
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
                    "Follow official emergency instructions and posted evacuation procedures. This prototype is an aid, not an authority.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote).foregroundStyle(.orange)
            }

            if !session.isSignedIn {
                BackendSignInView(session: session, title: "Sign in to see your buildings")
            }

            if let error = session.error, session.isSignedIn {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                    Button("Retry") { Task { await reload() } }.font(.caption)
                }
            }

            Section {
                if entries.isEmpty {
                    ContentUnavailableView(
                        session.isSignedIn ? "No Buildings Available" : "Sign In to Continue",
                        systemImage: "building.2",
                        description: Text(
                            session.isSignedIn
                            ? "No published buildings in your organization yet, and no maps on this device."
                            : "Sign in above to load buildings published by your organization."
                        )
                    )
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
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: session.isSignedIn) { _, signedIn in
            if signedIn { Task { await reload() } }
        }
    }

    private func reload() async {
        await repository.refresh()
        await session.refresh()
    }
}

struct BuildingRow: View {
    let entry: BuildingEntry

    private var tint: Color {
        switch entry.availability {
        case .offlineAvailable, .publishedByYou: return .green
        case .updateAvailable: return .yellow
        case .downloadFailed: return .red
        case .downloading: return .blue
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "building.2.fill")
                .font(.title3).foregroundStyle(.green)
                .frame(width: 36, height: 36)
                .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                Text(entry.availability.label).font(.caption2).foregroundStyle(tint)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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
    @State private var showLocalization = false
    @State private var locatedBy: BuildingLocalizationService.Method?

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
                Section { HStack { ProgressView(); Text("Loading map…") } }
            } else if effectiveGraph != nil {
                if !started { locationSection } else { routeSection; mapSection }
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
                        startNodeID = result.routePosition.nodeID ?? startNodeID
                        locatedBy = result.method
                        start()
                    },
                    onCancel: { showLocalization = false }
                )
            }
        }
    }

    private var statusSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(service.connection == .live ? .green : service.connection == .error ? .red : .orange)
                    .frame(width: 8, height: 8)
                Text(service.connection.displayName)
                Spacer()
                Text("rev \(service.revision)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if service.usingCache {
                Label("Using the cached map — live updates unavailable", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let package {
                Label(
                    "Offline map v\(package.version) · \(package.zones.filter(\.hasWorldMap).count) AR zone(s)",
                    systemImage: "arrow.down.circle.fill"
                )
                .font(.caption).foregroundStyle(.green)
            }
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Camera localization needs a downloaded package with at least one
    /// ARWorldMap — never offered when it could not possibly work.
    private var canLocalizeWithCamera: Bool {
        guard let package else { return false }
        return !BuildingLocalizationService.relocalizableZones(in: package).isEmpty
    }

    private var locationSection: some View {
        Section {
            if canLocalizeWithCamera {
                Button {
                    showLocalization = true
                } label: {
                    Label("I Don't Know Where I Am", systemImage: "location.magnifyingglass")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .tint(.blue)
            }

            Picker("I am at", selection: $startNodeID) {
                Text("Select a room…").tag(UUID?.none)
                ForEach(rooms) { node in
                    Text(node.name).tag(UUID?.some(node.id))
                }
            }
            Toggle("Avoid stairs", isOn: $profile.avoidStairs)
            Toggle("Wheelchair accessible only", isOn: $profile.requireWheelchairAccessible)

            Button {
                locatedBy = .manualSelection
                start()
            } label: {
                Label("Start Evacuation", systemImage: "figure.run")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .disabled(startNodeID == nil)
        } header: {
            Text("Where are you?")
        } footer: {
            if canLocalizeWithCamera {
                Text("Point the camera around you to be found automatically, or pick the nearest room.")
            } else if package == nil {
                Text("Download this building from Saved Maps to enable camera localization. Picking a room works either way.")
            } else {
                Text("This building has no AR map recorded, so pick the nearest room.")
            }
        }
    }

    @ViewBuilder
    private var routeSection: some View {
        Section {
            if let banner {
                Label(banner, systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.yellow)
            }
            if let best = options?.best {
                Text(best.destination.name).font(.title3.weight(.bold))
                Text("\(Int(best.totalDistanceMeters.rounded())) m · \(best.nodes.map(\.name).joined(separator: " → "))")
                    .font(.caption).foregroundStyle(.secondary)
                if best.isRefugeFallback {
                    Label("No exit reachable — routing to an area of refuge.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if let summary = options?.summary {
                    Text(summary).font(.caption2).foregroundStyle(.secondary)
                }
                if let locatedBy {
                    Text(locatedBy.displayName).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(loadError ?? "No route available.").foregroundStyle(.orange)
            }
            Button("Change location") { started = false }
                .font(.caption)
        } header: {
            Text("Evacuation route")
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

    private func start() {
        started = true
        recompute(announce: false)
    }

    private func recompute(announce: Bool, changedName: String? = nil) {
        guard let graph = effectiveGraph, let startNodeID,
              let node = graph.node(startNodeID) else { options = nil; return }
        let previous = options?.best.destination.id
        do {
            let result = try ShortestPathService.findBestEgressRoute(
                from: RoutePosition(nodeID: node.id, worldPosition: node.worldPosition),
                graph: graph, profile: profile
            )
            options = result
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
            loadError = error.localizedDescription
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
