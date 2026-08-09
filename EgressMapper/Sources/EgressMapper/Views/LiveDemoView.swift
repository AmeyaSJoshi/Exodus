import SwiftUI

/// Live Backend Demo — exercises the full backend path without AR, so live
/// rerouting can be tested in the Simulator.
///
/// It deliberately uses the *same* `BuildingGraph`, `LiveStateOverlay` and
/// `ShortestPathService` as AR navigation. Only the presentation differs.
struct LiveDemoView: View {
    @State private var service = SupabaseBuildingService()
    @State private var config = BackendConfig.load()
    @State private var email = "viewer@egress.test"
    @State private var password = "egress-viewer-pw"
    @State private var busy = false
    @State private var error: String?

    @State private var building: RemoteBuilding?
    @State private var startNodeID: UUID?
    @State private var profile = NavigationProfile.standard
    @State private var route: CalculatedRoute?
    @State private var banner: String?
    @State private var announcer = Announcer()

    private var effectiveGraph: BuildingGraph? {
        guard let graph = service.graph else { return nil }
        guard let overlay = service.overlay else { return graph }
        return overlay.effectiveGraph(from: graph)
    }

    var body: some View {
        List {
            connectionSection
            if service.signedInEmail == nil {
                signInSection
            } else {
                buildingSection
                if service.graph != nil {
                    startSection
                    routeSection
                    mapSection
                }
            }
        }
        .navigationTitle("Live Backend Demo")
        .navigationBarTitleDisplayMode(.inline)
        .task { try? service.configure(config) }
        .onDisappear { Task { await service.stopSubscription() } }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section {
            HStack {
                EGStatusBadge(status: EGStatus(connection: service.connection), compact: true)
                Spacer()
                // Developer screen: the raw revision is genuinely useful here.
                Text("rev \(service.revision)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .egAnimation(service.connection)
            if service.usingCache {
                Label("Using cached data — live updates unavailable", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(Color.egCaution)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let e = service.lastError {
                Text(e).font(.caption2).foregroundStyle(.orange)
            }
        } header: {
            Text("Backend")
        } footer: {
            Text("Simulator can use 127.0.0.1. A physical iPhone must use your Mac's LAN address.")
        }
    }

    private var signInSection: some View {
        Section("Sign in") {
            TextField("Backend URL", text: $config.url)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            SecureField("Anon key", text: $config.anonKey)
            TextField("Email", text: $email)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            SecureField("Password", text: $password)
            Button {
                Task { await signIn() }
            } label: {
                HStack {
                    if busy { ProgressView() }
                    Text("Sign in as occupant")
                }
            }
            .disabled(busy || config.anonKey.isEmpty)
        }
    }

    private var buildingSection: some View {
        Section("Building") {
            Text(service.signedInEmail ?? "").font(.caption).foregroundStyle(.secondary)
            ForEach(service.buildings) { b in
                Button {
                    Task { await select(b) }
                } label: {
                    HStack {
                        Text(b.name)
                        Spacer()
                        if building?.id == b.id { Image(systemName: "checkmark").foregroundStyle(.green) }
                    }
                }
            }
            Button("Sign out") { Task { await service.signOut(); building = nil; route = nil } }
                .foregroundStyle(.red)
        }
    }

    private var startSection: some View {
        Section("Start") {
            Picker("I am at", selection: $startNodeID) {
                Text("Select…").tag(UUID?.none)
                ForEach(service.graph?.nodes.filter { $0.type != .exit } ?? []) { n in
                    Text(n.name).tag(UUID?.some(n.id))
                }
            }
            .onChange(of: startNodeID) { _, _ in recalculate(announce: false) }

            Toggle("Avoid stairs", isOn: $profile.avoidStairs)
                .onChange(of: profile) { _, _ in recalculate(announce: false) }
            Toggle("Wheelchair accessible only", isOn: $profile.requireWheelchairAccessible)
                .onChange(of: profile) { _, _ in recalculate(announce: false) }
        }
    }

    @ViewBuilder
    private var routeSection: some View {
        Section {
            if let banner {
                Label(banner, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(Color.egCaution)
            }
            if let route {
                Text(route.destination.name).font(.title3.weight(.bold))
                Text("\(Int(route.totalDistanceMeters.rounded())) m · \(route.nodes.map(\.name).joined(separator: " → "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if route.isRefugeFallback {
                    Label("No exit reachable — routing to an area of refuge.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Color.egCaution)
                }
            } else if startNodeID != nil {
                Label("No safe route from here", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.egCaution)
            } else {
                Label("Choose a start location", systemImage: "mappin.and.ellipse")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Current route")
        }
    }

    private var mapSection: some View {
        Section {
            LiveGraphMapView(
                graph: effectiveGraph ?? service.graph!,
                route: route?.nodes ?? [],
                startNodeID: startNodeID
            )
            .frame(height: 260)
            .listRowInsets(EdgeInsets())
        }
    }

    // MARK: - Actions

    private func signIn() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try service.configure(config)
            try await service.signIn(email: email, password: password)
            try await service.loadBuildings()
            if let first = service.buildings.first { await select(first) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func select(_ b: RemoteBuilding) async {
        error = nil
        building = b
        route = nil
        banner = nil
        do {
            try await service.loadGraph(for: b)
            startNodeID = service.graph?.nodes.first(where: { $0.type == .room })?.id
                ?? service.graph?.nodes.first?.id

            // React to live changes using the same routing engine as AR mode.
            service.onStateChanged = { changed in
                Task { @MainActor in handleLiveChange(changed) }
            }
            try await service.subscribe(buildingID: b.id)
            recalculate(announce: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Recomputes from the *effective* graph. The permanent graph is untouched.
    private func recalculate(announce: Bool, changedName: String? = nil) {
        guard let graph = effectiveGraph, let startNodeID,
              let node = graph.node(startNodeID) else {
            route = nil
            return
        }
        let position = RoutePosition(nodeID: node.id, worldPosition: node.worldPosition)
        do {
            let options = try ShortestPathService.findBestEgressRoute(
                from: position, graph: graph, profile: profile
            )
            let previous = route?.destination.id
            route = options.best
            if announce, previous != options.best.destination.id {
                let message = LiveStateOverlay.changeMessage(
                    edgeName: changedName ?? "That route",
                    status: .blocked,
                    newExit: options.best.destination.name
                )
                banner = message
                announcer.say(message, force: true)
                announcer.haptic(.routeChanged)
            } else if announce {
                banner = "\(changedName ?? "Building state") changed. Route unaffected."
            }
        } catch {
            route = nil
            banner = error.localizedDescription
            if announce { announcer.say(error.localizedDescription, force: true) }
        }
    }

    private func handleLiveChange(_ changed: LiveEdgeState?) {
        guard let permanent = service.graph, let overlay = service.overlay else { return }

        var changedName: String?
        if let changed, let edge = permanent.edge(changed.edgeStableID) {
            let from = permanent.node(edge.fromNodeID)?.name ?? "A segment"
            let to = permanent.node(edge.toNodeID)?.name ?? "the next point"
            changedName = "\(from) → \(to)"
        }

        // Only announce when the route the user is following is affected.
        let affected = route.map { overlay.routeIsAffected($0) } ?? false
        recalculate(announce: changed != nil, changedName: changedName)

        if let changed, changed.status == .available, !affected {
            banner = "\(changedName ?? "A segment") is open again."
        }
    }
}

/// Top-down 2D map. Blocked edges are drawn dashed red; the active route green.
struct LiveGraphMapView: View {
    let graph: BuildingGraph
    let route: [RouteNode]
    let startNodeID: UUID?

    var body: some View {
        Canvas { context, size in
            let points = graph.nodes.map(\.mapPoint)
            guard !points.isEmpty else { return }
            let bounds = TopDownRouteView.bounds(of: points)
            let t = TopDownRouteView.fitTransform(bounds: bounds, into: size, padding: 34)

            for edge in graph.edges {
                guard let a = graph.node(edge.fromNodeID), let b = graph.node(edge.toNodeID) else { continue }
                var line = Path()
                line.move(to: t(a.mapPoint))
                line.addLine(to: t(b.mapPoint))
                context.stroke(
                    line,
                    with: .color(edge.isImpassable ? .red : .white.opacity(0.30)),
                    style: StrokeStyle(
                        lineWidth: edge.isImpassable ? 3 : 2,
                        dash: edge.isImpassable ? [6, 4] : []
                    )
                )
            }

            if route.count > 1 {
                var path = Path()
                path.move(to: t(route[0].mapPoint))
                for n in route.dropFirst() { path.addLine(to: t(n.mapPoint)) }
                context.stroke(path, with: .color(.green),
                               style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }

            var labels = EGMapLabelLayout()
            for node in graph.nodes {
                let p = t(node.mapPoint)
                let r: CGFloat = node.id == startNodeID ? 9 : 6
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect),
                             with: .color(node.id == startNodeID ? .cyan : node.type.tint))
                context.draw(
                    Text(node.name).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white),
                    at: labels.position(for: node.name, at: p, fontSize: 9)
                )
            }
        }
        .background(Color.black.opacity(0.6))
    }
}
