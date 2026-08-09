import Foundation
import simd

/// Locally stored accessibility and guidance preferences.
struct NavigationProfile: Codable, Hashable {
    var avoidStairs: Bool
    var requireWheelchairAccessible: Bool
    var avoidElevators: Bool
    var preferSimplerRoutes: Bool
    var audioGuidanceEnabled: Bool
    var hapticGuidanceEnabled: Bool

    init(
        avoidStairs: Bool = false,
        requireWheelchairAccessible: Bool = false,
        avoidElevators: Bool = false,
        preferSimplerRoutes: Bool = false,
        audioGuidanceEnabled: Bool = true,
        hapticGuidanceEnabled: Bool = true
    ) {
        self.avoidStairs = avoidStairs
        self.requireWheelchairAccessible = requireWheelchairAccessible
        self.avoidElevators = avoidElevators
        self.preferSimplerRoutes = preferSimplerRoutes
        self.audioGuidanceEnabled = audioGuidanceEnabled
        self.hapticGuidanceEnabled = hapticGuidanceEnabled
    }

    static let standard = NavigationProfile()
    static let wheelchair = NavigationProfile(
        avoidStairs: true, requireWheelchairAccessible: true
    )

    var hasAccessibilityConstraints: Bool {
        avoidStairs || requireWheelchairAccessible || avoidElevators
    }

    /// Human-readable summary for the "why did I get this route" explanation.
    var constraintSummary: String? {
        var parts: [String] = []
        if avoidStairs { parts.append("avoiding stairs") }
        if requireWheelchairAccessible { parts.append("wheelchair accessible") }
        if avoidElevators { parts.append("avoiding elevators") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - Position along the graph

struct RoutePosition: Codable, Hashable {
    var edgeID: UUID?
    var nodeID: UUID?
    var fractionAlongEdge: Double?
    var worldPosition: SIMD3<Float>

    init(
        edgeID: UUID? = nil,
        nodeID: UUID? = nil,
        fractionAlongEdge: Double? = nil,
        worldPosition: SIMD3<Float> = .zero
    ) {
        self.edgeID = edgeID
        self.nodeID = nodeID
        self.fractionAlongEdge = fractionAlongEdge
        self.worldPosition = worldPosition
    }

    /// True when the user is at a known vertex rather than mid-segment.
    var isAtNode: Bool { nodeID != nil }

    enum CodingKeys: String, CodingKey {
        case edgeID, nodeID, fractionAlongEdge, x, y, z
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edgeID = try c.decodeIfPresent(UUID.self, forKey: .edgeID)
        nodeID = try c.decodeIfPresent(UUID.self, forKey: .nodeID)
        fractionAlongEdge = try c.decodeIfPresent(Double.self, forKey: .fractionAlongEdge)
        worldPosition = SIMD3<Float>(
            try c.decode(Float.self, forKey: .x),
            try c.decode(Float.self, forKey: .y),
            try c.decode(Float.self, forKey: .z)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(edgeID, forKey: .edgeID)
        try c.encodeIfPresent(nodeID, forKey: .nodeID)
        try c.encodeIfPresent(fractionAlongEdge, forKey: .fractionAlongEdge)
        try c.encode(worldPosition.x, forKey: .x)
        try c.encode(worldPosition.y, forKey: .y)
        try c.encode(worldPosition.z, forKey: .z)
    }
}

enum LocationConfidence: String, Codable, Hashable {
    case high
    case medium
    case low
    case unavailable

    /// Navigation must never start automatically below this bar.
    var allowsAutomaticNavigation: Bool { self == .high || self == .medium }

    var displayName: String {
        switch self {
        case .high: return "High confidence"
        case .medium: return "Medium confidence"
        case .low: return "Low confidence"
        case .unavailable: return "Location unavailable"
        }
    }
}

struct LocationEstimate: Hashable {
    var routePosition: RoutePosition
    var nearestNodeName: String?
    var distanceFromRouteMeters: Double
    var confidence: LocationConfidence

    /// Centralised so they can be retuned after physical testing.
    enum Thresholds {
        static let high: Double = 1.5
        static let medium: Double = 3.0
    }

    static func confidence(forDistance distance: Double) -> LocationConfidence {
        if distance <= Thresholds.high { return .high }
        if distance <= Thresholds.medium { return .medium }
        return .low
    }
}

// MARK: - Route result

struct CalculatedRoute: Hashable {
    var nodes: [RouteNode]
    var edges: [RouteEdge]
    var totalDistanceMeters: Double
    var destination: RouteNode
    /// Why this route was chosen — surfaced to the user.
    var explanation: String
    /// True when routing to an area of refuge because no exit was reachable.
    var isRefugeFallback: Bool

    var isEmpty: Bool { nodes.count < 2 }
}

enum RoutingError: LocalizedError, Equatable {
    case unknownStart
    case unknownDestination
    case noRoute
    case noAccessibleRoute(constraints: String)
    case emptyGraph
    /// The map has no exit waypoint at all, so there is nothing to route to.
    case noExitsOnMap
    /// A route exists on the map, but live closures cut every one of them.
    case allRoutesBlocked(blockedSegments: Int)
    /// The start point has no connection to any exit even with nothing
    /// blocked — the map itself is missing a link.
    case startNotConnected(startName: String)

    var errorDescription: String? {
        switch self {
        case .unknownStart:
            return "Your starting position is not on the mapped route."
        case .unknownDestination:
            return "That destination is not part of this zone's map."
        case .noRoute:
            return "No route to an exit is available from here."
        case .noExitsOnMap:
            return "This map has no exit marked on it, so there is nothing to route to. Add an exit waypoint and publish again."
        case .allRoutesBlocked(let count):
            return count == 1
                ? "The only way out from here is currently blocked by an administrator."
                : "All \(count) routes out from here are currently blocked by an administrator."
        case .startNotConnected(let startName):
            return "“\(startName)” is not connected to any exit on this map — nothing is blocked, the map is missing a link. Re-map the zone so this point joins a corridor that reaches an exit."
        case .noAccessibleRoute(let constraints):
            return "No route matching your accessibility needs (\(constraints)) is available. All remaining paths are excluded."
        case .emptyGraph:
            return "This zone has no routable map yet. Map it in Configure first."
        }
    }
}
