import SwiftUI

/// Full-screen 2D evacuation guidance.
///
/// Used when AR is unavailable — no recorded world map for the building, or a
/// device without world tracking. It renders the route produced by the same
/// `ShortestPathService` the AR path uses; there is no second router.
struct TwoDGuidanceView: View {
    let buildingName: String
    let graph: BuildingGraph
    let route: CalculatedRoute
    let startNodeID: UUID
    var banner: String?
    var connection: ConnectionStatus
    var onExit: () -> Void

    @State private var legIndex = 0

    private var steps: [String] {
        guard route.nodes.count > 1 else { return ["You are already at \(route.destination.name)."] }
        return route.nodes.dropFirst().enumerated().map { index, node in
            let distance = index < route.edges.count
                ? Int(route.edges[index].distanceMeters.rounded())
                : 0
            return distance > 0 ? "\(node.name) — \(distance) m" : node.name
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            LiveGraphMapView(graph: graph, route: route.nodes, startNodeID: startNodeID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            steplist
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Evacuating").font(.caption).foregroundStyle(.secondary)
                    Text(route.destination.name).font(.title2.weight(.heavy))
                }
                Spacer()
                Button("Stop", role: .destructive, action: onExit)
                    .buttonStyle(.bordered)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(connection == .live ? .green : connection == .error ? .red : .orange)
                    .frame(width: 7, height: 7)
                Text("\(Int(route.totalDistanceMeters.rounded())) m")
                if route.isRefugeFallback {
                    Text("· area of refuge").foregroundStyle(.orange)
                }
                Spacer()
            }
            .font(.caption)

            if let banner {
                Label(banner, systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.yellow)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }

    private var steplist: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Follow this route").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 10) {
                        Image(systemName: index == steps.count - 1
                              ? "figure.run.square.stack.fill" : "arrow.turn.up.right")
                            .foregroundStyle(index == steps.count - 1 ? .green : .blue)
                            .frame(width: 22)
                        Text(step)
                        Spacer()
                    }
                    .font(.subheadline)
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 220)
        .background(.ultraThinMaterial)
    }
}
