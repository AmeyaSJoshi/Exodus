import SwiftUI

/// "Report a Problem" during navigation. Two steps — pick the problem, then
/// confirm exactly which route segment it affects — because blocking the
/// wrong segment sends someone the wrong way.
struct HazardReportView: View {
    let zone: MappingZone
    let graph: BuildingGraph
    /// Segments of the route currently being followed, in order.
    let routeEdges: [RouteEdge]
    /// Index of the segment directly ahead of the user — the default target.
    let currentLegIndex: Int
    let locationDescription: String
    let nextNodeName: String?
    var onConfirm: (RouteHazard, UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedType: RouteHazardType?
    @State private var targetEdgeID: UUID?
    @State private var choosingSegment = false

    private var defaultEdge: RouteEdge? {
        guard currentLegIndex >= 0, currentLegIndex < routeEdges.count else {
            return routeEdges.first
        }
        return routeEdges[currentLegIndex]
    }

    private var targetEdge: RouteEdge? {
        guard let targetEdgeID else { return defaultEdge }
        return routeEdges.first { $0.id == targetEdgeID } ?? graph.edge(targetEdgeID)
    }

    var body: some View {
        NavigationStack {
            Group {
                if selectedType == nil {
                    typePicker
                } else {
                    confirmation
                }
            }
            .navigationTitle(selectedType == nil ? "Report a Problem" : "Confirm Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if selectedType == nil { dismiss() } else { selectedType = nil }
                    }
                }
            }
        }
    }

    // MARK: - Step 1

    private var typePicker: some View {
        List {
            Section {
                ForEach(RouteHazardType.allCases, id: \.self) { type in
                    Button {
                        selectedType = type
                        targetEdgeID = defaultEdge?.id
                    } label: {
                        HStack {
                            Image(systemName: symbol(for: type))
                                .foregroundStyle(type.blocksTravel ? .red : .orange)
                                .frame(width: 26)
                            Text(type.displayName)
                            Spacer()
                            if !type.blocksTravel {
                                Text("passable")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Reports apply to this device only and are cleared from Configure. They do not notify anyone.")
            }
        }
    }

    // MARK: - Step 2

    @ViewBuilder
    private var confirmation: some View {
        if let type = selectedType {
            List {
                Section("Problem") {
                    Label(type.displayName, systemImage: symbol(for: type))
                        .foregroundStyle(type.blocksTravel ? .red : .orange)
                    Text(type.blocksTravel
                         ? "This segment will be removed from routing."
                         : "This segment stays usable but will be heavily avoided.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Where you are") {
                    Text(locationDescription).font(.subheadline)
                    if let nextNodeName {
                        LabeledContent("Next waypoint", value: nextNodeName)
                    }
                }

                Section {
                    if let edge = targetEdge {
                        Label(label(for: edge), systemImage: "arrow.triangle.turn.up.right.diamond")
                            .font(.subheadline.weight(.medium))
                    } else {
                        Text("No route segment available to mark.")
                            .foregroundStyle(.orange)
                    }
                    Button("Select a Different Segment") { choosingSegment = true }
                        .font(.caption)
                } header: {
                    Text("Affected segment")
                } footer: {
                    Text("By default this is the part of the route directly ahead of you.")
                }

                Section {
                    Button {
                        confirm(type)
                    } label: {
                        Label("Confirm", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(targetEdge == nil)
                }
            }
            .sheet(isPresented: $choosingSegment) {
                segmentPicker
            }
        }
    }

    private var segmentPicker: some View {
        NavigationStack {
            List {
                ForEach(routeEdges) { edge in
                    Button {
                        targetEdgeID = edge.id
                        choosingSegment = false
                    } label: {
                        HStack {
                            Text(label(for: edge))
                            Spacer()
                            if targetEdge?.id == edge.id {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                        .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Which Segment?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { choosingSegment = false }
                }
            }
        }
    }

    // MARK: - Helpers

    private func confirm(_ type: RouteHazardType) {
        guard let edge = targetEdge else { return }
        onConfirm(RouteHazard(type: type, severity: type.blocksTravel ? 5 : 3), edge.id)
        dismiss()
    }

    func label(for edge: RouteEdge) -> String {
        let from = graph.node(edge.fromNodeID)?.name ?? "Here"
        let to = graph.node(edge.toNodeID)?.name ?? "Next point"
        return "\(from) → \(to)"
    }

    private func symbol(for type: RouteHazardType) -> String {
        switch type {
        case .blockedHallway: return "xmark.octagon.fill"
        case .lockedDoor: return "lock.fill"
        case .smoke: return "smoke.fill"
        case .fire: return "flame.fill"
        case .unavailableStairwell: return "figure.stairs"
        case .unavailableElevator: return "arrow.up.arrow.down.square"
        case .other: return "exclamationmark.triangle.fill"
        }
    }
}

/// Configure-mode view of active hazards, kept separate from the permanent
/// building graph so clearing one never requires re-mapping.
struct ActiveHazardsView: View {
    @Environment(ZoneRepository.self) private var repository
    @State private var rows: [Row] = []

    struct Row: Identifiable {
        var id: UUID { edgeID }
        let zone: MappingZone
        let edgeID: UUID
        let hazard: RouteHazard
        let label: String
    }

    var body: some View {
        List {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Active Hazards",
                    systemImage: "checkmark.shield",
                    description: Text("Reported problems appear here and can be cleared without re-mapping.")
                )
            }

            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Label(row.hazard.type.displayName, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(row.hazard.type.blocksTravel ? .red : .orange)
                        .font(.subheadline.weight(.semibold))
                    Text(row.label).font(.caption)
                    Text("\(row.zone.displayTitle) · reported \(row.hazard.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        clear(row)
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }
            }

            if !rows.isEmpty {
                Section {
                    Button(role: .destructive) {
                        clearAll()
                    } label: {
                        Label("Clear All Hazards", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Active Hazards")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
    }

    private func reload() {
        var found: [Row] = []
        for zone in repository.zones {
            let active = repository.store.loadHazards(zone.id)
            guard !active.isEmpty, let graph = repository.graph(for: zone) else { continue }
            for (edgeID, hazard) in active.hazards {
                let label: String
                if let edge = graph.edge(edgeID) {
                    let from = graph.node(edge.fromNodeID)?.name ?? "?"
                    let to = graph.node(edge.toNodeID)?.name ?? "?"
                    label = "\(from) → \(to)"
                } else {
                    label = "Unknown segment"
                }
                found.append(Row(zone: zone, edgeID: edgeID, hazard: hazard, label: label))
            }
        }
        rows = found.sorted { $0.hazard.createdAt > $1.hazard.createdAt }
    }

    private func clear(_ row: Row) {
        var active = repository.store.loadHazards(row.zone.id)
        active.clear(row.edgeID)
        try? repository.store.saveHazards(active, zoneID: row.zone.id)
        reload()
    }

    private func clearAll() {
        for zone in repository.zones {
            try? repository.store.clearHazards(zone.id)
        }
        reload()
    }
}
