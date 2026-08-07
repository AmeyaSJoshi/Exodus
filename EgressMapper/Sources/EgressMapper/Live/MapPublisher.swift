import Foundation
import Supabase

/// Uploads a locally mapped zone as a draft map version and publishes it.
///
/// UUIDs are preserved: `RouteNode.id` / `RouteEdge.id` become the server's
/// `stable_id`, so a published map keeps the same identities the phone's AR
/// anchors already use, and live state can reference them directly.
struct MapPublisher {
    let client: SupabaseClient

    struct Result {
        var buildingID: UUID
        var mapVersionID: UUID
        var version: Int
        var nodeCount: Int
        var edgeCount: Int
        /// Binary artifacts uploaded alongside the graph, plus the manifest.
        var artifactCount: Int = 0
        var hasWorldMap: Bool = false
    }

    enum PublishError: LocalizedError {
        case emptyGraph
        case danglingEdges(Int)
        case notAdmin

        var errorDescription: String? {
            switch self {
            case .emptyGraph:
                return "This zone has no waypoints to publish."
            case .danglingEdges(let count):
                return "\(count) connection(s) reference a missing waypoint. Re-map the zone."
            case .notAdmin:
                return "Publishing requires an administrator account."
            }
        }
    }

    // MARK: - Wire payloads

    private struct NodeInsert: Encodable {
        let map_version_id: String
        let stable_id: String
        let floor_id: String
        let name: String
        let type: String
        let position: [String: Float]
    }

    private struct EdgeInsert: Encodable {
        let map_version_id: String
        let stable_id: String
        let from_node_stable_id: String
        let to_node_stable_id: String
        let distance_meters: Double
        let bidirectional: Bool
        let contains_stairs: Bool
        let requires_elevator: Bool
        let wheelchair_accessible: Bool
    }

    private struct BuildingRow: Decodable {
        let id: UUID
    }

    private struct MapVersionRow: Decodable {
        let id: UUID
        let version: Int
    }

    // MARK: - Validation

    /// Edges whose endpoints are not in the node set. Checked before upload so a
    /// bad graph is rejected locally rather than half-written to the server.
    static func danglingEdgeCount(in graph: BuildingGraph) -> Int {
        let ids = Set(graph.nodes.map(\.id))
        return graph.edges.filter { !ids.contains($0.fromNodeID) || !ids.contains($0.toNodeID) }.count
    }

    static func validate(_ graph: BuildingGraph) throws {
        guard !graph.nodes.isEmpty else { throw PublishError.emptyGraph }
        let dangling = danglingEdgeCount(in: graph)
        guard dangling == 0 else { throw PublishError.danglingEdges(dangling) }
    }

    // MARK: - Publish

    /// Creates the building if needed, uploads the graph and every localization
    /// artifact as a draft, then publishes. `publish_map_version` validates and
    /// archives the old version in one transaction, and it is only reached once
    /// all uploads have succeeded — a failure leaves a draft, never a
    /// half-published map.
    ///
    /// - Parameters:
    ///   - artifacts: ARWorldMap, reference viewpoints and floor plan bytes.
    ///   - aliases: extra OCR-searchable strings per node stable id.
    func publish(
        zone: MappingZone,
        graph: BuildingGraph,
        organizationID: UUID,
        existingBuildingID: UUID?,
        buildingName: String? = nil,
        artifacts: [PendingArtifact] = [],
        aliases: [UUID: [String]] = [:]
    ) async throws -> Result {
        try Self.validate(graph)

        let buildingID: UUID
        if let existingBuildingID {
            buildingID = existingBuildingID
        } else {
            let row: BuildingRow = try await client
                .from("buildings")
                .insert([
                    "organization_id": organizationID.uuidString,
                    "name": zone.building.isEmpty ? zone.displayTitle : zone.building,
                    "address": zone.campus,
                ])
                .select("id")
                .single()
                .execute()
                .value
            buildingID = row.id
        }

        let draft: MapVersionRow = try await client
            .rpc("create_draft_map_version", params: ["p_building_id": buildingID.uuidString])
            .select("id,version")
            .single()
            .execute()
            .value

        let floor = zone.floor.isEmpty ? "default" : zone.floor
        let nodeRows = graph.nodes.map { node in
            NodeInsert(
                map_version_id: draft.id.uuidString,
                stable_id: node.id.uuidString,
                floor_id: floor,
                name: node.name,
                type: node.type.rawValue,
                position: [
                    "x": node.worldPosition.x,
                    "y": node.worldPosition.y,
                    "z": node.worldPosition.z,
                ]
            )
        }
        // Batched so a large zone does not exceed the request size limit.
        for chunk in nodeRows.chunked(into: 200) {
            try await client.from("route_nodes").insert(chunk).execute()
        }

        let edgeRows = graph.edges.map { edge in
            EdgeInsert(
                map_version_id: draft.id.uuidString,
                stable_id: edge.id.uuidString,
                from_node_stable_id: edge.fromNodeID.uuidString,
                to_node_stable_id: edge.toNodeID.uuidString,
                distance_meters: edge.distanceMeters,
                bidirectional: edge.isBidirectional,
                contains_stairs: edge.accessibility.containsStairs,
                requires_elevator: edge.accessibility.requiresElevator,
                wheelchair_accessible: edge.accessibility.wheelchairAccessible
            )
        }
        for chunk in edgeRows.chunked(into: 200) {
            try await client.from("route_edges").insert(chunk).execute()
        }

        // The localization package: manifest built locally, artifacts uploaded
        // to Storage, rows written, and only then the version published.
        let manifest = try MapPackageBuilder.build(
            zone: zone,
            graph: graph,
            buildingID: buildingID,
            buildingName: buildingName ?? (zone.building.isEmpty ? zone.displayTitle : zone.building),
            mapVersionID: draft.id,
            version: draft.version,
            artifacts: artifacts,
            aliases: aliases
        )

        let outcome = try await MapPackagePublisher(
            uploader: SupabaseMapPackageUploader(client: client)
        ).publish(manifest: manifest, artifacts: artifacts, aliases: aliases)

        return Result(
            buildingID: buildingID,
            mapVersionID: draft.id,
            version: draft.version,
            nodeCount: nodeRows.count,
            edgeCount: edgeRows.count,
            artifactCount: outcome.artifactCount,
            hasWorldMap: manifest.zones.contains { $0.hasWorldMap }
        )
    }

    /// Collects everything on disk for a zone into upload-ready artifacts.
    /// A zone with no world map still publishes — its graph routes fine, it
    /// just cannot offer camera relocalization.
    static func artifacts(for zone: MappingZone, store: ZoneFileStore) -> [PendingArtifact] {
        var pending: [PendingArtifact] = []

        if let worldMap = store.worldMapData(zone.id) {
            DiagnosticsLog.shared.log("Publish: including world map, \(worldMap.count) bytes")
            pending.append(PendingArtifact(
                kind: .worldmap,
                zoneID: zone.id,
                fileName: "worldmap.arexperience",
                data: worldMap
            ))
        }

        if store.worldMapData(zone.id) == nil {
            DiagnosticsLog.shared.log(
                "Publish: no world map on disk for zone \(zone.id.uuidString.prefix(8)) — publishing routing data only"
            )
        }
        for view in store.referenceViews(zone.id) {
            guard let data = store.referenceViewData(view, zoneID: zone.id) else { continue }
            pending.append(PendingArtifact(
                kind: .referenceImage,
                zoneID: zone.id,
                fileName: view.fileName,
                viewpoint: view.viewpoint,
                data: data
            ))
        }

        if let floorPlan = store.loadFloorPlanImage(zone.id)?.jpegData(compressionQuality: 0.85) {
            pending.append(PendingArtifact(
                kind: .floorplan, zoneID: zone.id, fileName: "floorplan.jpg", data: floorPlan
            ))
        }

        return pending
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
