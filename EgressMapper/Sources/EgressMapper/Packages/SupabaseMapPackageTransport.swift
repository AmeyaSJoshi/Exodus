import Foundation
import Supabase

/// The Supabase side of map packages. Deliberately thin: every rule about
/// ordering, rollback and verification lives in `MapPackagePublisher` and
/// `MapPackageDownloader`, which are tested without a network.
///
/// Authorization is not enforced here. Storage RLS keys off the first path
/// segment (the building id) and the `map_artifacts` policies key off the
/// building, so an occupant's upload is rejected by the server regardless of
/// what the client attempts.
enum MapArtifactBucket {
    static let name = "map-artifacts"
}

struct SupabaseMapPackageUploader: MapPackageUploading {
    let client: SupabaseClient

    private var bucket: StorageFileApi { client.storage.from(MapArtifactBucket.name) }

    func upload(path: String, data: Data, contentType: String) async throws {
        // `upsert` so re-running a failed publish of the *same* draft version
        // succeeds. A published version never reuses its paths, so this cannot
        // overwrite a live map.
        try await bucket.upload(
            path, data: data, options: FileOptions(contentType: contentType, upsert: true)
        )
    }

    func remove(paths: [String]) async {
        guard !paths.isEmpty else { return }
        // Best effort: the publish already failed, and a leftover object in a
        // draft version is invisible to occupants either way.
        _ = try? await bucket.remove(paths: paths)
    }

    private struct ArtifactRow: Encodable {
        let map_version_id: String
        let building_id: String
        let zone_id: String?
        let kind: String
        let storage_path: String
        let byte_size: Int
        let checksum: String
        let schema_version: Int
        let metadata: [String: String]
    }

    func recordArtifacts(_ artifacts: [PackageArtifact], manifest: MapPackageManifest) async throws {
        let rows = artifacts.map { artifact in
            var metadata: [String: String] = [
                "local_file_name": artifact.localFileName,
                "floor_id": artifact.floorID ?? manifest.defaultFloorID,
            ]
            if let viewpoint = artifact.viewpoint { metadata["viewpoint"] = viewpoint }
            return ArtifactRow(
                map_version_id: manifest.mapVersionID.uuidString,
                building_id: manifest.buildingID.uuidString,
                zone_id: artifact.zoneID?.uuidString,
                kind: artifact.kind.rawValue,
                storage_path: artifact.storagePath,
                byte_size: artifact.byteSize,
                checksum: artifact.checksum,
                schema_version: manifest.schemaVersion,
                metadata: metadata
            )
        }
        guard !rows.isEmpty else { return }
        try await client.from("map_artifacts").insert(rows).execute()
    }

    private struct AliasRow: Encodable {
        let map_version_id: String
        let node_stable_id: String
        let alias: String
        let source: String
    }

    func recordAliases(_ aliases: [UUID: [String]], mapVersionID: UUID) async throws {
        let rows = aliases.flatMap { nodeID, values in
            values.map {
                AliasRow(
                    map_version_id: mapVersionID.uuidString,
                    node_stable_id: nodeID.uuidString,
                    alias: $0,
                    source: "manual"
                )
            }
        }
        guard !rows.isEmpty else { return }
        try await client.from("room_aliases").insert(rows).execute()
    }

    func publishVersion(mapVersionID: UUID) async throws {
        _ = try await client
            .rpc("publish_map_version", params: ["p_map_version_id": mapVersionID.uuidString])
            .execute()
    }
}

/// Reads a published package. The manifest is fetched from Storage when it was
/// uploaded as one; older versions that predate packages are reconstructed from
/// the route tables so an existing published map still downloads.
struct SupabaseMapPackageSource: MapPackageFetching {
    let client: SupabaseClient

    private var bucket: StorageFileApi { client.storage.from(MapArtifactBucket.name) }

    private struct ArtifactRow: Decodable {
        let kind: String
        let storage_path: String
        let byte_size: Int
        let checksum: String?
        let zone_id: UUID?
        let schema_version: Int
        let metadata: [String: String]?
    }

    private struct BuildingRow: Decodable {
        let id: UUID
        let name: String
    }

    private struct VersionRow: Decodable {
        let id: UUID
        let version: Int
    }

    func manifest(buildingID: UUID, mapVersionID: UUID) async throws -> MapPackageManifest {
        let path = MapPackageBuilder.storagePath(
            buildingID: buildingID,
            mapVersionID: mapVersionID,
            fileName: MapPackageBuilder.manifestFileName
        )
        if let data = try? await bucket.download(path: path),
           let manifest = try? MapPackageCoder.decode(data) {
            return manifest
        }
        // Published before packages existed: build an equivalent manifest from
        // the graph tables so the download path still works for it.
        return try await reconstructedManifest(buildingID: buildingID, mapVersionID: mapVersionID)
    }

    func download(path: String) async throws -> Data {
        try await bucket.download(path: path)
    }

    /// A graph-only manifest with no binary artifacts. Verification passes
    /// trivially and the building becomes offline-available for routing, but it
    /// carries no ARWorldMap, so camera relocalization is unavailable until the
    /// mapper republishes.
    private func reconstructedManifest(
        buildingID: UUID, mapVersionID: UUID
    ) async throws -> MapPackageManifest {
        async let buildingTask: BuildingRow = client
            .from("buildings").select("id,name").eq("id", value: buildingID.uuidString)
            .single().execute().value
        async let versionTask: VersionRow = client
            .from("map_versions").select("id,version").eq("id", value: mapVersionID.uuidString)
            .single().execute().value
        async let nodesTask: [RemoteRouteNode] = client
            .from("route_nodes").select("stable_id,floor_id,name,type,position")
            .eq("map_version_id", value: mapVersionID.uuidString).execute().value
        async let edgesTask: [RemoteRouteEdge] = client
            .from("route_edges")
            .select("stable_id,from_node_stable_id,to_node_stable_id,distance_meters,bidirectional,contains_stairs,requires_elevator,wheelchair_accessible")
            .eq("map_version_id", value: mapVersionID.uuidString).execute().value

        let building = try await buildingTask
        let versionRow = try await versionTask
        let graph = RemoteGraphMapper.graph(
            buildingID: buildingID, nodes: try await nodesTask, edges: try await edgesTask
        )
        let aliases = try await self.aliases(mapVersionID: mapVersionID)

        // The zone stands in for the building itself: there is no recorded
        // mapping zone to attribute these nodes to.
        let zone = MappingZone(
            id: buildingID,
            campus: "",
            building: building.name,
            floor: "default",
            zoneName: building.name
        )
        return try MapPackageBuilder.build(
            zone: zone,
            graph: graph,
            buildingID: buildingID,
            buildingName: building.name,
            mapVersionID: mapVersionID,
            version: versionRow.version,
            artifacts: [],
            aliases: aliases
        )
    }

    private struct AliasRow: Decodable {
        let node_stable_id: UUID
        let alias: String
    }

    func aliases(mapVersionID: UUID) async throws -> [UUID: [String]] {
        let rows: [AliasRow] = try await client
            .from("room_aliases").select("node_stable_id,alias")
            .eq("map_version_id", value: mapVersionID.uuidString)
            .execute().value
        return Dictionary(grouping: rows, by: \.node_stable_id).mapValues { $0.map(\.alias) }
    }
}
