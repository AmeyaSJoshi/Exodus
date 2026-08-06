import SwiftUI

/// Automatic egress: the user does not pick a destination — the router
/// evaluates every exit and recommends the cheapest reachable one, then
/// explains the choice and what was ruled out.
struct EmergencyRouteView: View {
    let zone: MappingZone
    let start: RoutePosition
    let estimate: LocationEstimate

    @Environment(ZoneRepository.self) private var repository
    @State private var graph: BuildingGraph?
    @State private var waypoints: [Waypoint] = []
    @State private var path = RoutePath()
    @State private var profile = NavigationProfile.standard
    @State private var options: ShortestPathService.EgressOptions?
    @State private var chosen: CalculatedRoute?
    @State private var routeError: String?
    @State private var navigating = false
    @State private var showAlternatives = false

    private var activeRoute: CalculatedRoute? { chosen ?? options?.best }

    var body: some View {
        Form {
            if let routeError {
                Section {
                    Label(routeError, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)

                    // An accessibility constraint blocking every path is
                    // recoverable — offer the way out instead of dead-ending.
                    if profile.hasAccessibilityConstraints {
                        Text("Active constraints: \(profile.constraintSummary ?? "none").")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            profile = NavigationProfile(
                                audioGuidanceEnabled: profile.audioGuidanceEnabled,
                                hapticGuidanceEnabled: profile.hapticGuidanceEnabled
                            )
                        } label: {
                            Label("Clear constraints and use the standard route", systemImage: "arrow.counterclockwise")
                        }
                    }

                    Text("Follow posted evacuation signage and staff instructions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            locationSection
            if activeRoute != nil {
                recommendationSection
                previewSection
                alternativesSection
            }
            accessibilitySection
            if activeRoute != nil { startSection }
        }
        .navigationTitle("Get Out")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $navigating) {
            if let route = activeRoute {
                GuidanceView(
                    zone: zone,
                    route: route.nodes,
                    path: path,
                    allWaypoints: waypoints,
                    routeEdges: route.edges,
                    rerouteContext: .init(start: start)
                ) {
                    navigating = false
                }
                .environment(repository)
            }
        }
        .task { load() }
        .onChange(of: profile) { _, updated in
            try? repository.store.saveProfile(updated)
            // Accessibility changes must reroute immediately, never be ignored.
            chosen = nil
            recompute()
        }
    }

    // MARK: - Sections

    private var locationSection: some View {
        Section("You are here") {
            Label(LocalizationService.describe(estimate, zone: zone), systemImage: "location.fill")
                .font(.subheadline.weight(.medium))
            Text(estimate.confidence.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recommendationSection: some View {
        if let route = activeRoute, let options {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: route.isRefugeFallback ? "shield.lefthalf.filled" : "figure.run")
                            .foregroundStyle(route.isRefugeFallback ? .mint : .green)
                        Text(route.destination.name)
                            .font(.title3.weight(.bold))
                        Spacer()
                        Text("\(Int(route.totalDistanceMeters.rounded())) m")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Text(chosen == nil ? options.summary : route.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if route.isRefugeFallback {
                        Label(
                            "No exit is reachable. This routes to an area of refuge — stay there and make yourself known to responders.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text(chosen == nil ? "Recommended exit" : "Selected exit")
            }
        }
    }

    private var previewSection: some View {
        Section {
            TopDownRouteView(
                path: path,
                waypoints: waypoints,
                currentPosition: MapPoint(projecting: start.worldPosition),
                highlightedRoute: activeRoute?.nodes ?? []
            )
            .frame(height: 200)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private var alternativesSection: some View {
        if let options, !options.alternatives.isEmpty || !options.unreachable.isEmpty {
            Section {
                DisclosureGroup("Other exits", isExpanded: $showAlternatives) {
                    ForEach(options.alternatives, id: \.destination.id) { route in
                        Button {
                            chosen = route
                        } label: {
                            HStack {
                                Image(systemName: route.destination.type.symbolName)
                                Text(route.destination.name)
                                Spacer()
                                Text("\(Int(route.totalDistanceMeters.rounded())) m")
                                    .foregroundStyle(.secondary)
                                if chosen?.destination.id == route.destination.id {
                                    Image(systemName: "checkmark").foregroundStyle(.green)
                                }
                            }
                            .font(.subheadline)
                        }
                    }

                    ForEach(options.unreachable, id: \.node.id) { blocked in
                        HStack(alignment: .top) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(blocked.node.name)
                                Text(blocked.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)
                    }

                    if chosen != nil {
                        Button("Use recommended exit") { chosen = nil }
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var accessibilitySection: some View {
        Section {
            Button {
                withAnimation {
                    profile.avoidStairs = true
                    profile.requireWheelchairAccessible = true
                }
            } label: {
                Label("I Need an Accessible Route", systemImage: "figure.roll")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .disabled(profile.avoidStairs && profile.requireWheelchairAccessible)

            Toggle("Avoid stairs", isOn: $profile.avoidStairs)
            Toggle("Wheelchair accessible only", isOn: $profile.requireWheelchairAccessible)
            Toggle("Avoid elevators", isOn: $profile.avoidElevators)
        } header: {
            Text("Accessibility")
        } footer: {
            Text("Changing these reroutes immediately. If nothing satisfies them, the app says so rather than quietly ignoring your needs.")
        }
    }

    private var startSection: some View {
        Section {
            Button {
                navigating = true
            } label: {
                Label("Start Guidance", systemImage: "location.north.line.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .disabled(!zone.hasWorldMap)
        } footer: {
            if !zone.hasWorldMap {
                Text("This zone has no saved world map, so AR guidance is unavailable. The 2D route above still applies.")
            }
        }
    }

    // MARK: - Loading

    private func load() {
        profile = repository.store.loadProfile()
        waypoints = repository.store.loadWaypoints(zone.id)
        path = repository.store.loadPath(zone.id)
        graph = repository.routableGraph(for: zone)
        recompute()
    }

    private func recompute() {
        guard let graph else {
            routeError = RoutingError.emptyGraph.localizedDescription
            return
        }
        do {
            options = try ShortestPathService.findBestEgressRoute(
                from: start, graph: graph, profile: profile
            )
            routeError = nil
            DiagnosticsLog.shared.log("Egress: \(options?.summary ?? "-")")
        } catch {
            options = nil
            routeError = error.localizedDescription
            DiagnosticsLog.shared.log("Egress failed: \(error.localizedDescription)")
        }
    }
}
