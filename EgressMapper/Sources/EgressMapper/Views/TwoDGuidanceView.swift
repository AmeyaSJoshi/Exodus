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
            EvacuationMapView(
                graph: graph,
                route: route.nodes,
                currentNodeID: startNodeID,
                nextNodeID: route.nodes.count > 1 ? route.nodes[1].id : nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            steplist
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: EG.Space.s) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Evacuating to").font(.caption).foregroundStyle(.secondary)
                    Text(route.destination.name)
                        .font(.title.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(Int(route.totalDistanceMeters.rounded())) m · \(steps.count) steps")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: EG.Space.s)
                Button("Stop", role: .destructive, action: onExit)
                    .buttonStyle(.bordered)
                    .frame(minHeight: EG.minTarget)
                    .accessibilityLabel("Stop navigation")
            }
            .accessibilityElement(children: .contain)

            HStack(spacing: EG.Space.s) {
                EGStatusBadge(status: EGStatus(connection: connection), compact: true)
                if route.isRefugeFallback {
                    Label("Area of refuge", systemImage: "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(Color.egCaution)
                }
            }

            if let banner {
                EGBanner(
                    title: banner,
                    tone: .caution,
                    symbol: "arrow.triangle.branch"
                )
                .modifier(EGTransition())
            }
        }
        .padding(EG.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .egAnimation(banner)
        .egAnimation(route.destination.id)
    }

    private var steplist: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EG.Space.m) {
                Text("FOLLOW THIS ROUTE")
                    .font(.caption.weight(.semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    let isLast = index == steps.count - 1
                    HStack(spacing: EG.Space.m) {
                        Image(systemName: isLast ? "flag.checkered" : "arrow.turn.up.right")
                            .foregroundStyle(isLast ? Color.egSafe : .secondary)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(step)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(.body)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(EG.Space.l)
        }
        .frame(maxHeight: 240)
        .background(.ultraThinMaterial)
    }
}
