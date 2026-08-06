import Foundation
import simd

/// The persisted, routable representation of one mapped zone.
/// Derived from `waypoints.json` + `path.json`; those source files are never
/// modified, so a graph can always be rebuilt.
struct BuildingGraph: Codable, Hashable {
    static let currentVersion = 1

    var version: Int
    var zoneID: UUID
    var nodes: [RouteNode]
    var edges: [RouteEdge]

    init(version: Int = BuildingGraph.currentVersion, zoneID: UUID, nodes: [RouteNode], edges: [RouteEdge]) {
        self.version = version
        self.zoneID = zoneID
        self.nodes = nodes
        self.edges = edges
    }

    var isEmpty: Bool { nodes.isEmpty }
    var needsMigration: Bool { version < Self.currentVersion }

    func node(_ id: UUID) -> RouteNode? { nodes.first { $0.id == id } }
    func edge(_ id: UUID) -> RouteEdge? { edges.first { $0.id == id } }

    var exits: [RouteNode] { nodes.filter { $0.type.isEgressTarget } }
    var refuges: [RouteNode] { nodes.filter { $0.type.isRefuge } }

    /// Edges incident to a node, respecting one-way edges.
    func incidentEdges(_ nodeID: UUID) -> [RouteEdge] {
        edges.filter { $0.fromNodeID == nodeID || ($0.isBidirectional && $0.toNodeID == nodeID) }
    }

    // MARK: - Hazards (applied without mutating stored geometry)

    /// Returns a copy with active hazards applied to the matching edges.
    /// The permanent graph on disk is never changed by this.
    func applying(hazards: [UUID: RouteHazard]) -> BuildingGraph {
        guard !hazards.isEmpty else { return self }
        var copy = self
        copy.edges = edges.map { edge in
            guard let hazard = hazards[edge.id] else { return edge }
            var updated = edge
            updated.hazard = hazard
            if hazard.type.blocksTravel { updated.isBlocked = true }
            return updated
        }
        return copy
    }

    // MARK: - Temporary start node

    /// Inserts an in-memory node at `fraction` along `edgeID`, splitting that
    /// edge in two. Used when the user is standing mid-hallway. The returned
    /// graph is a value copy — the saved graph is untouched.
    func insertingTemporaryStart(
        onEdge edgeID: UUID,
        fraction: Double,
        nodeID: UUID = UUID()
    ) -> (graph: BuildingGraph, startNodeID: UUID)? {
        guard let edge = edge(edgeID),
              let from = node(edge.fromNodeID),
              let to = node(edge.toNodeID) else { return nil }

        let t = Float(max(0, min(1, fraction)))
        let position = from.worldPosition + (to.worldPosition - from.worldPosition) * t

        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)

        let temp = RouteNode(
            id: nodeID,
            name: "Your Location",
            type: .temporaryStart,
            position: CodableTransform(transform),
            zoneID: zoneID
        )

        let clamped = max(0, min(1, fraction))
        let head = RouteEdge(
            fromNodeID: temp.id,
            toNodeID: edge.fromNodeID,
            distanceMeters: edge.distanceMeters * clamped,
            isBidirectional: true,
            isBlocked: edge.isBlocked,
            accessibility: edge.accessibility,
            hazard: edge.hazard
        )
        let tail = RouteEdge(
            fromNodeID: temp.id,
            toNodeID: edge.toNodeID,
            distanceMeters: edge.distanceMeters * (1 - clamped),
            isBidirectional: true,
            isBlocked: edge.isBlocked,
            accessibility: edge.accessibility,
            hazard: edge.hazard
        )

        var copy = self
        copy.nodes.append(temp)
        // The original edge stays; the split edges simply offer a cheaper way
        // in from the user's actual position.
        copy.edges.append(contentsOf: [head, tail])
        return (copy, temp.id)
    }

    /// Strips all run-time-only graph data.
    func removingTemporaryData() -> BuildingGraph {
        let tempIDs = Set(nodes.filter { $0.type == .temporaryStart }.map(\.id))
        guard !tempIDs.isEmpty else { return self }
        var copy = self
        copy.nodes.removeAll { tempIDs.contains($0.id) }
        copy.edges.removeAll { tempIDs.contains($0.fromNodeID) || tempIDs.contains($0.toNodeID) }
        return copy
    }
}

/// Active hazards, persisted separately from the permanent graph so they can
/// be cleared without re-mapping the building.
struct ActiveHazards: Codable, Hashable {
    var zoneID: UUID
    /// Keyed by edge id.
    var hazards: [UUID: RouteHazard]

    init(zoneID: UUID, hazards: [UUID: RouteHazard] = [:]) {
        self.zoneID = zoneID
        self.hazards = hazards
    }

    var isEmpty: Bool { hazards.isEmpty }

    mutating func set(_ hazard: RouteHazard, on edgeID: UUID) {
        hazards[edgeID] = hazard
    }

    mutating func clear(_ edgeID: UUID) {
        hazards.removeValue(forKey: edgeID)
    }

    mutating func clearAll() {
        hazards.removeAll()
    }
}
