import SwiftUI

/// Manual fallback for setting a start position. Always reachable — camera
/// relocalization is an optimisation, never a requirement.
struct ManualLocationPickerView: View {
    let zone: MappingZone
    let graph: BuildingGraph
    let waypoints: [Waypoint]
    let path: RoutePath
    var onSelect: (RoutePosition, LocationEstimate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tapped: MapPoint?
    @State private var tappedEstimate: LocationEstimate?

    private func nodes(_ types: Set<RouteNodeType>) -> [RouteNode] {
        graph.nodes.filter { types.contains($0.type) }.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    mapPicker
                        .listRowInsets(EdgeInsets())
                } header: {
                    Text("Tap where you are")
                } footer: {
                    if let tappedEstimate {
                        Text(LocalizationService.describe(tappedEstimate, zone: zone))
                    } else {
                        Text("Tap the map to place yourself approximately.")
                    }
                }

                if let tappedEstimate, tappedEstimate.confidence != .unavailable {
                    Button {
                        onSelect(tappedEstimate.routePosition, tappedEstimate)
                        dismiss()
                    } label: {
                        Label("Use This Location", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                }

                group("Rooms", nodes([.room]))
                group("Stairs & Elevators", nodes([.stairwell, .elevator]))
                group("Landmarks", nodes([.intersection, .hallwayPoint, .refugeArea]))
                group("Exits", nodes([.exit]))
            }
            .navigationTitle("Where Are You?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [RouteNode]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { node in
                    Button {
                        select(node)
                    } label: {
                        HStack {
                            Image(systemName: symbol(for: node.type))
                            Text(node.name)
                            Spacer()
                            Text(node.type.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var mapPicker: some View {
        GeometryReader { geo in
            ZStack {
                TopDownRouteView(
                    path: path,
                    waypoints: waypoints,
                    currentPosition: tapped
                )
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleTap(location, in: geo.size)
            }
        }
        .frame(height: 240)
    }

    private func handleTap(_ location: CGPoint, in size: CGSize) {
        var points = path.simplified().map(\.mapPoint) + waypoints.map(\.mapPoint)
        if let tapped { points.append(tapped) }
        guard !points.isEmpty else { return }

        let bounds = TopDownRouteView.bounds(of: points)
        let inverse = TopDownRouteView.inverseFitTransform(bounds: bounds, into: size, padding: 24)
        let mapPoint = inverse(location)
        tapped = mapPoint

        // Reuse the same snapping logic the camera path uses.
        let world = SIMD3<Float>(Float(mapPoint.x), 0, Float(mapPoint.y))
        tappedEstimate = LocalizationService.estimate(worldPosition: world, graph: graph)
    }

    private func select(_ node: RouteNode) {
        let position = RoutePosition(nodeID: node.id, worldPosition: node.worldPosition)
        let estimate = LocationEstimate(
            routePosition: position,
            nearestNodeName: node.name,
            distanceFromRouteMeters: 0,
            // User-asserted, so treat as reliable — they can see where they are.
            confidence: .high
        )
        onSelect(position, estimate)
        dismiss()
    }

    private func symbol(for type: RouteNodeType) -> String {
        switch type {
        case .room: return "door.left.hand.closed"
        case .intersection, .hallwayPoint: return "arrow.triangle.branch"
        case .stairwell: return "figure.stairs"
        case .elevator: return "arrow.up.arrow.down.square"
        case .exit: return "figure.run.square.stack"
        case .refugeArea: return "shield.lefthalf.filled"
        case .temporaryStart: return "location.fill"
        }
    }
}
