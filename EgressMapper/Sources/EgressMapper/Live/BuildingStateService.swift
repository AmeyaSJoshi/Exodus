import Foundation
import simd


/// Where the app talks to. Kept configurable so a physical iPhone can reach the
/// Mac's LAN address instead of localhost, which means nothing on the phone.
struct BackendConfig: Codable, Hashable {
    var url: String
    var anonKey: String

    static let defaultsURLKey = "egress.backend.url"
    static let defaultsKeyKey = "egress.backend.anonKey"

    var isConfigured: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty
            && !anonKey.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: url) != nil
    }

    /// Simulator can use localhost; a physical phone must use the Mac's LAN IP.
    static let simulatorDefault = BackendConfig(url: "http://127.0.0.1:54321", anonKey: "")

    static func load() -> BackendConfig {
        let d = UserDefaults.standard
        return BackendConfig(
            url: d.string(forKey: defaultsURLKey) ?? simulatorDefault.url,
            anonKey: d.string(forKey: defaultsKeyKey) ?? ""
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(url, forKey: Self.defaultsURLKey)
        d.set(anonKey, forKey: Self.defaultsKeyKey)
    }
}

enum ConnectionStatus: String, Equatable {
    case offline
    case connecting
    case live
    case error

    var displayName: String {
        switch self {
        case .offline: return "Offline"
        case .connecting: return "Connecting…"
        case .live: return "Live"
        case .error: return "Connection error"
        }
    }
}

struct RemoteBuilding: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var address: String?
    var activeMapVersionID: UUID?

    // Georeference anchor (migration 20260806000900). Null until an
    // administrator sets the building's location on the dashboard; the focus
    // map needs all of it to place the local AR frame on the real world.
    var anchorLat: Double?
    var anchorLng: Double?
    var anchorAltM: Double?
    var headingDeg: Double?
    var scale: Double?
    var formattedAddress: String?

    // OSM building footprint, cached into the row by the dashboard (migration
    // 20260806001000). The phone never calls Overpass itself — it reads what
    // the console already resolved.
    var footprintGeoJSON: FootprintPolygon?
    var footprintHeightM: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, address, scale
        case activeMapVersionID = "active_map_version_id"
        case anchorLat = "anchor_lat"
        case anchorLng = "anchor_lng"
        case anchorAltM = "anchor_alt_m"
        case headingDeg = "heading_deg"
        case formattedAddress = "formatted_address"
        case footprintGeoJSON = "footprint_geojson"
        case footprintHeightM = "footprint_height_m"
    }

    /// The anchor is only usable when both coordinates are present.
    var anchor: BuildingAnchor? {
        guard let anchorLat, let anchorLng else { return nil }
        return BuildingAnchor(
            latitude: anchorLat,
            longitude: anchorLng,
            altitudeM: anchorAltM ?? 0,
            headingDeg: headingDeg ?? 0,
            scale: (scale ?? 1) > 0 ? (scale ?? 1) : 1
        )
    }
}

/// A GeoJSON Polygon as stored in `buildings.footprint_geojson`. Only the
/// outer ring is used; the dashboard's Overpass proxy never emits holes.
struct FootprintPolygon: Codable, Hashable {
    var type: String
    var coordinates: [[[Double]]]

    /// Serialised as a GeoJSON Feature, which is what MapLibre's shape parser
    /// expects — a bare geometry is not accepted by `MLNShape(data:encoding:)`.
    func featureData() throws -> Data {
        let feature: [String: Any] = [
            "type": "Feature",
            "properties": [:],
            "geometry": ["type": type, "coordinates": coordinates],
        ]
        return try JSONSerialization.data(withJSONObject: feature)
    }
}

/// A building's georeference, resolved into non-optional values.
struct BuildingAnchor: Hashable {
    var latitude: Double
    var longitude: Double
    var altitudeM: Double
    var headingDeg: Double
    var scale: Double
}

/// The seam the demo screen and AR navigation both use. Deliberately does no
/// routing — it only reports what the building's condition is.
protocol BuildingStateService: AnyObject {
    func fetchSnapshot(buildingID: UUID) async throws -> BuildingStateSnapshot
    func subscribe(buildingID: UUID) async throws
    func stopSubscription() async
}

enum BackendError: LocalizedError {
    case notConfigured
    case notSignedIn
    case noPublishedMap
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No backend configured. Set the URL and anon key in Live Backend Demo."
        case .notSignedIn:
            return "Sign in first."
        case .noPublishedMap:
            return "This building has no published map version yet."
        case .decoding(let detail):
            return "Could not read the server response: \(detail)"
        }
    }
}

// MARK: - Wire models

/// Server row shapes. Kept separate from the domain models so a schema change
/// cannot silently reshape the router's input.
struct RemoteRouteNode: Codable {
    var stableID: UUID
    var floorID: String
    var name: String
    var type: String
    var position: Position

    struct Position: Codable {
        var x: Float
        var y: Float
        var z: Float
    }

    enum CodingKeys: String, CodingKey {
        case stableID = "stable_id"
        case floorID = "floor_id"
        case name, type, position
    }
}

struct RemoteRouteEdge: Codable {
    var stableID: UUID
    var fromNodeStableID: UUID
    var toNodeStableID: UUID
    var distanceMeters: Double
    var bidirectional: Bool
    var containsStairs: Bool
    var requiresElevator: Bool
    var wheelchairAccessible: Bool

    enum CodingKeys: String, CodingKey {
        case stableID = "stable_id"
        case fromNodeStableID = "from_node_stable_id"
        case toNodeStableID = "to_node_stable_id"
        case distanceMeters = "distance_meters"
        case bidirectional
        case containsStairs = "contains_stairs"
        case requiresElevator = "requires_elevator"
        case wheelchairAccessible = "wheelchair_accessible"
    }
}

/// Converts server rows into the existing domain graph.
/// `stable_id` becomes `RouteNode.id` / `RouteEdge.id`, so ids stay identical
/// across the phone, the database and the dashboard.
enum RemoteGraphMapper {
    static func graph(
        buildingID: UUID,
        nodes: [RemoteRouteNode],
        edges: [RemoteRouteEdge]
    ) -> BuildingGraph {
        let mapped = nodes.map { remote -> RouteNode in
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4<Float>(remote.position.x, remote.position.y, remote.position.z, 1)
            return RouteNode(
                id: remote.stableID,
                name: remote.name,
                type: RouteNodeType(rawValue: remote.type) ?? .hallwayPoint,
                position: CodableTransform(m),
                zoneID: buildingID,
                floorID: remote.floorID
            )
        }

        let known = Set(mapped.map(\.id))
        let mappedEdges = edges.compactMap { remote -> RouteEdge? in
            // Drop edges whose endpoints are missing rather than producing a
            // graph the router would traverse into nowhere.
            guard known.contains(remote.fromNodeStableID), known.contains(remote.toNodeStableID) else {
                return nil
            }
            return RouteEdge(
                id: remote.stableID,
                fromNodeID: remote.fromNodeStableID,
                toNodeID: remote.toNodeStableID,
                distanceMeters: remote.distanceMeters,
                isBidirectional: remote.bidirectional,
                isBlocked: false,
                accessibility: EdgeAccessibility(
                    containsStairs: remote.containsStairs,
                    requiresElevator: remote.requiresElevator,
                    wheelchairAccessible: remote.wheelchairAccessible
                )
            )
        }

        return BuildingGraph(zoneID: buildingID, nodes: mapped, edges: mappedEdges)
    }
}
