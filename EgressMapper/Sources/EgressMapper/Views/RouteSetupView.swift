import SwiftUI

struct RouteSetupView: View {
    let zone: MappingZone

    @Environment(ZoneRepository.self) private var repository
    @State private var waypoints: [Waypoint] = []
    @State private var path = RoutePath()
    @State private var graph: BuildingGraph?
    @State private var profile = NavigationProfile.standard
    @State private var start: Waypoint?
    @State private var destination: Waypoint?
    @State private var loadError: String?
    @State private var routeError: String?
    @State private var navigating = false
    @State private var aligningFloorPlan = false

    /// Waypoints for the route the router picked, in order.
    private var route: [Waypoint] {
        guard let calculated else { return [] }
        // Node ids equal waypoint ids, so this mapping is exact.
        return calculated.nodes.compactMap { node in
            waypoints.first { $0.id == node.id }
        }
    }

    private var calculated: CalculatedRoute? {
        guard let graph, let start, let destination else { return nil }
        let position = RoutePosition(nodeID: start.id, worldPosition: start.position)
        return try? ShortestPathService.findRoute(
            from: position, to: destination.id, graph: graph, profile: profile
        )
    }

    private var destinations: [Waypoint] {
        let exits = waypoints.filter { $0.type.isDestination }
        return exits.isEmpty ? waypoints : exits
    }

    var body: some View {
        Form {
            errorSection
            zoneSection
            if !waypoints.isEmpty {
                previewSection
                startSection
                destinationSection
                accessibilitySection
                launchSection
            }
        }
        .navigationTitle(zone.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $navigating) {
            if !route.isEmpty {
                GuidanceView(zone: zone, route: route, path: path, allWaypoints: waypoints) {
                    navigating = false
                }
                .environment(repository)
            }
        }
        .sheet(isPresented: $aligningFloorPlan) {
            FloorPlanAlignmentView(zone: zone, waypoints: waypoints, path: path)
                .environment(repository)
        }
        .task { load() }
        .onChange(of: profile) { _, updated in
            try? repository.store.saveProfile(updated)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var errorSection: some View {
        if let loadError {
            Section {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var zoneSection: some View {
        Section("Zone") {
            LabeledContent("Building", value: zone.building)
            LabeledContent("Floor", value: zone.floor)
            LabeledContent("Waypoints", value: "\(waypoints.count)")
            LabeledContent("Recorded", value: zone.formattedLength)
            LabeledContent("World map", value: zone.hasWorldMap ? "Saved" : "Missing")
            if let graph {
                LabeledContent("Graph", value: "\(graph.nodes.count) nodes · \(graph.edges.count) edges")
            }
        }
    }

    private var previewSection: some View {
        Section {
            TopDownRouteView(
                path: path,
                waypoints: waypoints,
                highlightedRoute: route
            )
            .frame(height: 220)
            .listRowInsets(EdgeInsets())
        } header: {
            Text("Preview")
        }
    }

    private var startSection: some View {
        Section("Start") {
            Picker("Start at", selection: $start) {
                Text("Select…").tag(Waypoint?.none)
                ForEach(waypoints) { w in
                    Text(w.name).tag(Waypoint?.some(w))
                }
            }
        }
    }

    private var destinationSection: some View {
        Section {
            Picker("Exit to", selection: $destination) {
                Text("Select…").tag(Waypoint?.none)
                ForEach(destinations) { w in
                    Text(w.name).tag(Waypoint?.some(w))
                }
            }
        } header: {
            Text("Destination")
        } footer: {
            routeSummary
        }
    }

    private var accessibilitySection: some View {
        Section {
            Toggle("Avoid stairs", isOn: $profile.avoidStairs)
            Toggle("Wheelchair accessible only", isOn: $profile.requireWheelchairAccessible)
            Toggle("Avoid elevators", isOn: $profile.avoidElevators)
        } header: {
            Text("Accessibility")
        } footer: {
            Text("Routes that violate these are excluded outright, never quietly downgraded.")
        }
    }

    @ViewBuilder
    private var routeSummary: some View {
        if let calculated {
            Text("\(calculated.nodes.map(\.name).joined(separator: " → ")) · \(Int(calculated.totalDistanceMeters)) m")
        } else if start != nil && destination != nil {
            Text(unroutableReason)
                .foregroundStyle(.orange)
        }
    }

    /// Asks the router for the real reason rather than guessing.
    private var unroutableReason: String {
        guard let graph, let start, let destination else { return "Select a start and destination." }
        let position = RoutePosition(nodeID: start.id, worldPosition: start.position)
        do {
            _ = try ShortestPathService.findRoute(
                from: position, to: destination.id, graph: graph, profile: profile
            )
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    private var launchSection: some View {
        Section {
            Button {
                navigating = true
            } label: {
                Label("Start AR Navigation", systemImage: "location.north.line.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(route.count < 2 || !zone.hasWorldMap)

            Button {
                aligningFloorPlan = true
            } label: {
                Label(
                    zone.hasFloorPlan ? "Edit Floor-Plan Alignment" : "Align a Floor Plan (optional)",
                    systemImage: "square.on.square.dashed"
                )
                .frame(maxWidth: .infinity)
            }
        } footer: {
            if !zone.hasWorldMap {
                Text("This zone has no saved world map, so the phone cannot relocalize. Re-map the zone.")
            }
        }
    }

    // MARK: - Loading

    private func load() {
        profile = repository.store.loadProfile()
        guard let bundle = repository.loadBundle(zone) else {
            loadError = "This zone has no saved waypoints. It may be incomplete — try re-mapping it."
            return
        }
        waypoints = bundle.waypoints
        path = bundle.path
        graph = repository.routableGraph(for: zone)
        if graph == nil {
            loadError = "This zone has no routable graph yet."
        }
        start = waypoints.first
        destination = destinations.last
    }
}
