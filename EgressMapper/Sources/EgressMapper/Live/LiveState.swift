import Foundation

/// Server-reported status of one graph element.
enum LiveStatus: String, Codable, Hashable {
    case available
    case blocked
    case restricted

    /// `restricted` stays passable but heavily penalised, like smoke.
    var blocksTravel: Bool { self == .blocked }
}

struct LiveEdgeState: Codable, Hashable, Identifiable {
    var edgeStableID: UUID
    var status: LiveStatus
    var hazardType: String?
    var reason: String?
    var severity: Int
    var revision: Int64
    var expiresAt: Date?

    var id: UUID { edgeStableID }

    enum CodingKeys: String, CodingKey {
        case edgeStableID = "edge_stable_id"
        case status, hazardType = "hazard_type", reason, severity, revision
        case expiresAt = "expires_at"
    }

    /// Expired state is treated as cleared, so a client that was offline past an
    /// expiry does not keep honouring it.
    func isActive(now: Date = Date()) -> Bool {
        guard status != .available else { return false }
        if let expiresAt, expiresAt <= now { return false }
        return true
    }
}

struct LiveNodeState: Codable, Hashable, Identifiable {
    var nodeStableID: UUID
    var status: LiveStatus
    var reason: String?
    var severity: Int
    var revision: Int64
    var expiresAt: Date?

    var id: UUID { nodeStableID }

    enum CodingKeys: String, CodingKey {
        case nodeStableID = "node_stable_id"
        case status, reason, severity, revision
        case expiresAt = "expires_at"
    }

    func isActive(now: Date = Date()) -> Bool {
        guard status != .available else { return false }
        if let expiresAt, expiresAt <= now { return false }
        return true
    }
}

/// Everything the server knows about a building's current condition.
struct BuildingStateSnapshot: Codable, Hashable {
    var buildingID: UUID
    var revision: Int64
    var edges: [LiveEdgeState]
    var nodes: [LiveNodeState]

    enum CodingKeys: String, CodingKey {
        case buildingID = "building_id"
        case revision, edges, nodes
    }

    static func empty(buildingID: UUID) -> BuildingStateSnapshot {
        BuildingStateSnapshot(buildingID: buildingID, revision: 0, edges: [], nodes: [])
    }
}

/// The mutable layer that sits between the permanent graph and routing.
///
/// The permanent graph is never modified. `effectiveGraph(from:)` returns a
/// value copy with live state applied, which is what the router sees.
struct LiveStateOverlay: Equatable {
    private(set) var buildingID: UUID
    private(set) var revision: Int64 = 0
    private(set) var edgeStates: [UUID: LiveEdgeState] = [:]
    private(set) var nodeStates: [UUID: LiveNodeState] = [:]

    /// This user's own unverified report. Applied locally only — one person's
    /// report must never change every phone.
    private(set) var personalEdgeBlocks: Set<UUID> = []

    init(buildingID: UUID) {
        self.buildingID = buildingID
    }

    // MARK: - Applying server state

    /// Replaces everything. Used for the initial fetch and after reconnecting,
    /// where the server snapshot is authoritative.
    mutating func replace(with snapshot: BuildingStateSnapshot) {
        guard snapshot.buildingID == buildingID else { return }
        edgeStates = Dictionary(uniqueKeysWithValues: snapshot.edges.map { ($0.edgeStableID, $0) })
        nodeStates = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.nodeStableID, $0) })
        revision = max(snapshot.revision, highestRevision)
    }

    /// Applies one realtime event. Returns true only if something changed, so
    /// callers can skip needless rerouting.
    @discardableResult
    mutating func apply(edge state: LiveEdgeState) -> Bool {
        // Stale or duplicate delivery.
        if let existing = edgeStates[state.edgeStableID], state.revision <= existing.revision {
            return false
        }
        if state.revision <= 0 { return false }
        let changed = edgeStates[state.edgeStableID]?.status != state.status
        edgeStates[state.edgeStableID] = state
        revision = max(revision, state.revision)
        return changed
    }

    @discardableResult
    mutating func apply(node state: LiveNodeState) -> Bool {
        if let existing = nodeStates[state.nodeStableID], state.revision <= existing.revision {
            return false
        }
        if state.revision <= 0 { return false }
        let changed = nodeStates[state.nodeStableID]?.status != state.status
        nodeStates[state.nodeStableID] = state
        revision = max(revision, state.revision)
        return changed
    }

    private var highestRevision: Int64 {
        max(
            edgeStates.values.map(\.revision).max() ?? 0,
            nodeStates.values.map(\.revision).max() ?? 0
        )
    }

    // MARK: - Personal (unverified) reports

    mutating func addPersonalBlock(edgeID: UUID) {
        personalEdgeBlocks.insert(edgeID)
    }

    mutating func clearPersonalBlocks() {
        personalEdgeBlocks.removeAll()
    }

    // MARK: - Effective graph

    /// Edge ids the router must not use.
    func blockedEdgeIDs(now: Date = Date()) -> Set<UUID> {
        var blocked = personalEdgeBlocks
        for (id, state) in edgeStates where state.isActive(now: now) && state.status.blocksTravel {
            blocked.insert(id)
        }
        // A blocked node takes its incident edges with it; resolved in
        // effectiveGraph where the topology is known.
        return blocked
    }

    func blockedNodeIDs(now: Date = Date()) -> Set<UUID> {
        Set(nodeStates.filter { $0.value.isActive(now: now) && $0.value.status.blocksTravel }.keys)
    }

    /// Edges that are passable but should be avoided (e.g. `restricted`).
    func restrictedEdgeIDs(now: Date = Date()) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for (id, state) in edgeStates where state.isActive(now: now) && state.status == .restricted {
            result[id] = state.severity
        }
        return result
    }

    /// Produces the graph the router should use. The input graph is untouched.
    func effectiveGraph(from permanent: BuildingGraph, now: Date = Date()) -> BuildingGraph {
        let blockedEdges = blockedEdgeIDs(now: now)
        let blockedNodes = blockedNodeIDs(now: now)
        let restricted = restrictedEdgeIDs(now: now)
        guard !blockedEdges.isEmpty || !blockedNodes.isEmpty || !restricted.isEmpty else {
            return permanent
        }

        var copy = permanent
        copy.edges = permanent.edges.map { edge in
            var updated = edge
            let touchesBlockedNode =
                blockedNodes.contains(edge.fromNodeID) || blockedNodes.contains(edge.toNodeID)

            if blockedEdges.contains(edge.id) || touchesBlockedNode {
                updated.isBlocked = true
                if let state = edgeStates[edge.id] {
                    updated.hazard = RouteHazard(
                        type: Self.hazardType(from: state.hazardType),
                        description: state.reason ?? "Blocked by an administrator",
                        severity: state.severity
                    )
                }
            } else if let severity = restricted[edge.id] {
                updated.hazard = RouteHazard(
                    type: .smoke,
                    description: edgeStates[edge.id]?.reason ?? "Restricted",
                    severity: severity
                )
            }
            return updated
        }
        return copy
    }

    /// True when the given route uses anything currently blocked.
    func routeIsAffected(_ route: CalculatedRoute, now: Date = Date()) -> Bool {
        let blockedEdges = blockedEdgeIDs(now: now)
        let blockedNodes = blockedNodeIDs(now: now)
        if route.edges.contains(where: { blockedEdges.contains($0.id) }) { return true }
        if route.nodes.contains(where: { blockedNodes.contains($0.id) }) { return true }
        return false
    }

    static func hazardType(from raw: String?) -> RouteHazardType {
        guard let raw, let parsed = RouteHazardType(rawValue: raw) else { return .blockedHallway }
        return parsed
    }

    /// Human sentence for the reroute banner and speech.
    static func changeMessage(edgeName: String, status: LiveStatus, newExit: String?) -> String {
        switch status {
        case .blocked:
            let tail = newExit.map { " Rerouting to \($0)." } ?? ""
            return "\(edgeName) was blocked by an administrator.\(tail)"
        case .restricted:
            return "\(edgeName) is restricted. Looking for a better route."
        case .available:
            return "\(edgeName) is open again."
        }
    }
}
