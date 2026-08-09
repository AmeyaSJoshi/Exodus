import Foundation
import CryptoKit
import simd

/// The complete published description of one building map version: the route
/// graph, the mapping zones, and references to every binary artifact.
///
/// Binaries live in Supabase Storage; this manifest only carries their paths,
/// sizes and checksums, so the same value describes a package whether it is
/// being uploaded, downloaded or read from the local cache.
struct MapPackageManifest: Codable, Hashable {
    /// Bumped only when an older client could no longer read the package.
    static let currentSchemaVersion = 1
    /// Anything at or below this is still readable by this build.
    static let minimumReadableSchemaVersion = 1

    var schemaVersion: Int
    var buildingID: UUID
    var buildingName: String
    var mapVersionID: UUID
    var version: Int
    var defaultFloorID: String
    var createdAt: Date

    var zones: [PackageZone]
    var nodes: [PackageNode]
    var edges: [PackageEdge]
    var artifacts: [PackageArtifact]

    var isSchemaSupported: Bool {
        schemaVersion >= Self.minimumReadableSchemaVersion && schemaVersion <= Self.currentSchemaVersion
    }

    func artifact(_ id: UUID) -> PackageArtifact? { artifacts.first { $0.id == id } }
    func zone(_ id: UUID) -> PackageZone? { zones.first { $0.id == id } }

    /// Every node the OCR matcher can resolve a scanned sign to.
    var aliasIndex: [String: UUID] {
        var index: [String: UUID] = [:]
        for node in nodes {
            for alias in node.searchableAliases {
                index[MapPackageManifest.normalize(alias)] = node.stableID
            }
        }
        return index
    }

    /// Aliases are matched case- and punctuation-insensitively: a sign reading
    /// "Rm. 214" must resolve to the node named "Room 214".
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// One mapped AR area inside the building. Its `id` is the local zone's UUID,
/// preserved across publication so anchors keep their identity.
struct PackageZone: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var floorID: String
    var building: String
    /// Artifact holding the ARWorldMap for this zone, when one was recorded.
    var worldMapArtifactID: UUID?
    /// Reference photographs, ideally from several directions.
    var referenceImageArtifactIDs: [UUID]
    /// Node stable IDs that fall inside this zone — the localization search set.
    var nodeStableIDs: [UUID]

    var hasWorldMap: Bool { worldMapArtifactID != nil }
}

struct PackageNode: Codable, Hashable, Identifiable {
    var stableID: UUID
    var name: String
    var type: RouteNodeType
    var floorID: String
    var zoneID: UUID
    var position: PackagePoint
    /// Room number or other human label, when the node is a room.
    var roomNumber: String?
    /// Extra strings OCR may see on a sign for this node.
    var aliases: [String]
    var accessibility: NodeAccessibility

    var id: UUID { stableID }

    /// The name always counts as an alias, plus the room number if set.
    var searchableAliases: [String] {
        var all = aliases + [name]
        if let roomNumber { all.append(roomNumber) }
        return all.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

struct NodeAccessibility: Codable, Hashable {
    var wheelchairAccessible: Bool = true
    var hasStairs: Bool = false
    var isElevator: Bool = false

    init(wheelchairAccessible: Bool = true, hasStairs: Bool = false, isElevator: Bool = false) {
        self.wheelchairAccessible = wheelchairAccessible
        self.hasStairs = hasStairs
        self.isElevator = isElevator
    }

    init(nodeType: RouteNodeType) {
        self.init(
            wheelchairAccessible: nodeType != .stairwell,
            hasStairs: nodeType == .stairwell,
            isElevator: nodeType == .elevator
        )
    }
}

struct PackagePoint: Codable, Hashable {
    var x: Float
    var y: Float
    var z: Float
}

struct PackageEdge: Codable, Hashable, Identifiable {
    var stableID: UUID
    var fromNodeStableID: UUID
    var toNodeStableID: UUID
    var distanceMeters: Double
    var bidirectional: Bool
    var containsStairs: Bool
    var requiresElevator: Bool
    var wheelchairAccessible: Bool

    var id: UUID { stableID }
}

/// A binary file belonging to the package.
struct PackageArtifact: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case worldmap
        case referenceImage = "reference_image"
        case floorplan
        /// The manifest itself, so the package is self-describing in Storage.
        case package
    }

    var id: UUID
    var kind: Kind
    var zoneID: UUID?
    var floorID: String?
    /// Path inside the `map-artifacts` bucket, `<building>/<version>/<file>`.
    var storagePath: String
    var byteSize: Int
    /// Lowercase hex SHA-256 of the exact bytes at `storagePath`.
    var checksum: String
    /// Which way the camera was facing, so the UI can tell the user where to
    /// stand. Free text — "north corridor", "from the stairwell".
    var viewpoint: String?
    var localFileName: String
}

// MARK: - Checksums

enum PackageChecksum {
    /// Lowercase hex SHA-256. Used for every artifact and for the manifest.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ data: Data, expected: String) -> Bool {
        // Constant-time comparison is unnecessary here (no secret), but a
        // case-insensitive one avoids spurious failures across producers.
        sha256(data).caseInsensitiveCompare(expected) == .orderedSame
    }
}

// MARK: - Building a manifest

/// The bytes of one artifact, paired with the metadata describing it. The
/// builder computes the checksum and size so a caller cannot get them wrong.
struct PendingArtifact {
    var id: UUID
    var kind: PackageArtifact.Kind
    var zoneID: UUID?
    var floorID: String?
    var fileName: String
    var viewpoint: String?
    var data: Data

    init(
        id: UUID = UUID(),
        kind: PackageArtifact.Kind,
        zoneID: UUID? = nil,
        floorID: String? = nil,
        fileName: String,
        viewpoint: String? = nil,
        data: Data
    ) {
        self.id = id
        self.kind = kind
        self.zoneID = zoneID
        self.floorID = floorID
        self.fileName = fileName
        self.viewpoint = viewpoint
        self.data = data
    }
}

enum MapPackageError: LocalizedError, Equatable {
    case emptyGraph
    case danglingEdges([UUID])
    case danglingArtifactZone(UUID)
    case checksumMismatch(String)
    case unsupportedSchema(Int)
    case missingArtifact(String)
    case incompleteUpload(uploaded: Int, expected: Int)

    var errorDescription: String? {
        switch self {
        case .emptyGraph:
            return "This map has no waypoints to publish."
        case .danglingEdges(let ids):
            return "\(ids.count) connection(s) reference a missing waypoint. Re-map the zone."
        case .danglingArtifactZone(let id):
            return "An artifact refers to mapping zone \(id.uuidString), which is not in this package."
        case .checksumMismatch(let file):
            return "“\(file)” failed its integrity check and was discarded."
        case .unsupportedSchema(let version):
            return "This map was published in a newer format (v\(version)). Update the app to use it."
        case .missingArtifact(let path):
            return "A required map file is missing: \(path)."
        case .incompleteUpload(let uploaded, let expected):
            return "Only \(uploaded) of \(expected) map files uploaded. The version stays a draft."
        }
    }
}

enum MapPackageBuilder {

    /// Storage layout: `<building_id>/<map_version_id>/<file>`. The first path
    /// segment is what the Storage RLS policies authorize against.
    static func storagePath(buildingID: UUID, mapVersionID: UUID, fileName: String) -> String {
        "\(buildingID.uuidString)/\(mapVersionID.uuidString)/\(fileName)"
    }

    static let manifestFileName = "manifest.json"

    /// Builds the manifest for one zone's graph. Node and edge UUIDs are copied
    /// through unchanged — the published map keeps the identities the phone's
    /// AR anchors and live state already use.
    static func build(
        zone: MappingZone,
        graph: BuildingGraph,
        buildingID: UUID,
        buildingName: String,
        mapVersionID: UUID,
        version: Int,
        artifacts pending: [PendingArtifact],
        aliases: [UUID: [String]] = [:],
        createdAt: Date = Date()
    ) throws -> MapPackageManifest {
        guard !graph.nodes.isEmpty else { throw MapPackageError.emptyGraph }

        let nodeIDs = Set(graph.nodes.map(\.id))
        let dangling = graph.edges
            .filter { !nodeIDs.contains($0.fromNodeID) || !nodeIDs.contains($0.toNodeID) }
            .map(\.id)
        guard dangling.isEmpty else { throw MapPackageError.danglingEdges(dangling) }

        let floorID = zone.floor.isEmpty ? "default" : zone.floor

        for artifact in pending {
            if let zoneID = artifact.zoneID, zoneID != zone.id {
                throw MapPackageError.danglingArtifactZone(zoneID)
            }
        }

        let described = pending.map { item in
            PackageArtifact(
                id: item.id,
                kind: item.kind,
                zoneID: item.zoneID,
                floorID: item.floorID ?? floorID,
                storagePath: storagePath(
                    buildingID: buildingID, mapVersionID: mapVersionID, fileName: item.fileName
                ),
                byteSize: item.data.count,
                checksum: PackageChecksum.sha256(item.data),
                viewpoint: item.viewpoint,
                localFileName: item.fileName
            )
        }

        let nodes = graph.nodes.map { node in
            PackageNode(
                stableID: node.id,
                name: node.name,
                type: node.type,
                floorID: floorID,
                zoneID: zone.id,
                position: PackagePoint(
                    x: node.worldPosition.x, y: node.worldPosition.y, z: node.worldPosition.z
                ),
                roomNumber: node.type == .room ? roomNumber(from: node.name) : nil,
                aliases: aliases[node.id] ?? [],
                accessibility: NodeAccessibility(nodeType: node.type)
            )
        }

        let edges = graph.edges.map { edge in
            PackageEdge(
                stableID: edge.id,
                fromNodeStableID: edge.fromNodeID,
                toNodeStableID: edge.toNodeID,
                distanceMeters: edge.distanceMeters,
                bidirectional: edge.isBidirectional,
                containsStairs: edge.accessibility.containsStairs,
                requiresElevator: edge.accessibility.requiresElevator,
                wheelchairAccessible: edge.accessibility.wheelchairAccessible
            )
        }

        let packageZone = PackageZone(
            id: zone.id,
            name: zone.displayTitle,
            floorID: floorID,
            building: zone.building,
            worldMapArtifactID: described.first { $0.kind == .worldmap }?.id,
            referenceImageArtifactIDs: described.filter { $0.kind == .referenceImage }.map(\.id),
            nodeStableIDs: nodes.map(\.stableID)
        )

        return MapPackageManifest(
            schemaVersion: MapPackageManifest.currentSchemaVersion,
            buildingID: buildingID,
            buildingName: buildingName,
            mapVersionID: mapVersionID,
            version: version,
            defaultFloorID: floorID,
            // Millisecond resolution is all ISO8601 stores. Truncating here
            // means a manifest re-encoded from disk hashes to the same
            // checksum it was uploaded with.
            createdAt: Date(
                timeIntervalSince1970: (createdAt.timeIntervalSince1970 * 1000).rounded() / 1000
            ),
            zones: [packageZone],
            nodes: nodes,
            edges: edges,
            artifacts: described
        )
    }

    /// "Room 214" → "214". Nil when the name carries no number, so a hallway
    /// point does not gain a meaningless room number.
    static func roomNumber(from name: String) -> String? {
        let digits = name.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
        return digits.last
    }

    /// Rebuilds the routable graph from a manifest, so a downloaded package
    /// feeds the *existing* `ShortestPathService` with no second router.
    static func graph(from manifest: MapPackageManifest) -> BuildingGraph {
        let zoneID = manifest.zones.first?.id ?? manifest.buildingID
        let nodes = manifest.nodes.map { node in
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4<Float>(node.position.x, node.position.y, node.position.z, 1)
            return RouteNode(
                id: node.stableID,
                name: node.name,
                type: node.type,
                position: CodableTransform(m),
                zoneID: node.zoneID
            )
        }
        let edges = manifest.edges.map { edge in
            RouteEdge(
                id: edge.stableID,
                fromNodeID: edge.fromNodeStableID,
                toNodeID: edge.toNodeStableID,
                distanceMeters: edge.distanceMeters,
                isBidirectional: edge.bidirectional,
                accessibility: EdgeAccessibility(
                    containsStairs: edge.containsStairs,
                    requiresElevator: edge.requiresElevator,
                    wheelchairAccessible: edge.wheelchairAccessible
                )
            )
        }
        return BuildingGraph(zoneID: zoneID, nodes: nodes, edges: edges)
    }
}

// MARK: - Verification

enum MapPackageValidator {

    /// Checks schema compatibility, then that every artifact's bytes hash to
    /// the checksum the manifest promised. A package failing either is never
    /// written over a previously good cached version.
    static func verify(
        manifest: MapPackageManifest,
        files: [String: Data]
    ) throws {
        guard manifest.isSchemaSupported else {
            throw MapPackageError.unsupportedSchema(manifest.schemaVersion)
        }
        for artifact in manifest.artifacts where artifact.kind != .package {
            guard let data = files[artifact.storagePath] else {
                throw MapPackageError.missingArtifact(artifact.storagePath)
            }
            guard PackageChecksum.matches(data, expected: artifact.checksum) else {
                throw MapPackageError.checksumMismatch(artifact.localFileName)
            }
            guard data.count == artifact.byteSize else {
                throw MapPackageError.checksumMismatch(artifact.localFileName)
            }
        }
    }
}
