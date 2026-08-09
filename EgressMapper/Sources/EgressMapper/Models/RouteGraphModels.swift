import Foundation
import SwiftUI
import simd

// MARK: - Nodes

enum RouteNodeType: String, Codable, CaseIterable, Hashable {
    case room
    case intersection
    case hallwayPoint
    case stairwell
    case elevator
    case exit
    case refugeArea
    /// Synthesised at run time when the user is mid-edge. Never persisted.
    case temporaryStart

    /// Where the router is allowed to finish an evacuation.
    var isEgressTarget: Bool { self == .exit }
    /// Acceptable shelter when no exit is reachable.
    var isRefuge: Bool { self == .refugeArea }

    var displayName: String {
        switch self {
        case .room: return "Room"
        case .intersection: return "Intersection"
        case .hallwayPoint: return "Hallway Point"
        case .stairwell: return "Stairwell"
        case .elevator: return "Elevator"
        case .exit: return "Exit"
        case .refugeArea: return "Area of Refuge"
        case .temporaryStart: return "Your Location"
        }
    }

    var symbolName: String {
        switch self {
        case .room: return "door.left.hand.closed"
        case .intersection, .hallwayPoint: return "arrow.triangle.branch"
        case .stairwell: return "figure.stairs"
        case .elevator: return "arrow.up.arrow.down.square"
        case .exit: return "figure.run.square.stack"
        case .refugeArea: return "shield.lefthalf.filled"
        case .temporaryStart: return "location.fill"
        }
    }

    var tint: Color {
        switch self {
        case .room: return .blue
        case .intersection, .hallwayPoint: return .orange
        case .stairwell: return .purple
        case .elevator: return .teal
        case .exit: return .green
        case .refugeArea: return .mint
        case .temporaryStart: return .cyan
        }
    }

    var uiColor: UIColor {
        switch self {
        case .room: return .systemBlue
        case .intersection, .hallwayPoint: return .systemOrange
        case .stairwell: return .systemPurple
        case .elevator: return .systemTeal
        case .exit: return .systemGreen
        case .refugeArea: return .systemMint
        case .temporaryStart: return .systemCyan
        }
    }

    init(_ waypointType: WaypointType) {
        switch waypointType {
        case .room: self = .room
        case .intersection: self = .intersection
        case .stairwell: self = .stairwell
        case .elevator: self = .elevator
        case .exit: self = .exit
        case .refugeArea: self = .refugeArea
        }
    }
}

struct RouteNode: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var type: RouteNodeType
    var position: CodableTransform
    var zoneID: UUID
    /// Which floor the node sits on. Always present: zones saved before
    /// multi-floor existed are filled in at the decode boundary below, so no
    /// read site has to second-guess it.
    var floorID: String

    /// The floor a node belongs to when nothing said otherwise — a
    /// single-floor building, or a zone mapped before floors existed.
    static let defaultFloorID = "default"

    init(
        id: UUID = UUID(),
        name: String,
        type: RouteNodeType,
        position: CodableTransform,
        zoneID: UUID,
        floorID: String = RouteNode.defaultFloorID
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.position = position
        self.zoneID = zoneID
        self.floorID = floorID
    }

    /// The one place legacy data is repaired: a zone written before `floorID`
    /// existed decodes as the default floor rather than forcing every consumer
    /// to handle an absent value.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(RouteNodeType.self, forKey: .type)
        position = try c.decode(CodableTransform.self, forKey: .position)
        zoneID = try c.decode(UUID.self, forKey: .zoneID)
        floorID = try c.decodeIfPresent(String.self, forKey: .floorID) ?? RouteNode.defaultFloorID
    }

    var worldPosition: SIMD3<Float> { position.position }
    var mapPoint: MapPoint { MapPoint(projecting: worldPosition) }

    func distance(to other: RouteNode) -> Double {
        Double(simd_distance(worldPosition, other.worldPosition))
    }
}

// MARK: - Edges

struct EdgeAccessibility: Codable, Hashable {
    var containsStairs: Bool
    var requiresElevator: Bool
    var wheelchairAccessible: Bool

    static let standard = EdgeAccessibility(
        containsStairs: false, requiresElevator: false, wheelchairAccessible: true
    )

    /// Derived from the endpoints: a segment touching a stairwell involves
    /// stairs, and stairs are not wheelchair accessible.
    static func between(_ a: RouteNodeType, _ b: RouteNodeType) -> EdgeAccessibility {
        let stairs = a == .stairwell || b == .stairwell
        let elevator = a == .elevator || b == .elevator
        return EdgeAccessibility(
            containsStairs: stairs,
            requiresElevator: elevator,
            wheelchairAccessible: !stairs
        )
    }
}

enum RouteHazardType: String, Codable, CaseIterable, Hashable {
    case blockedHallway
    case lockedDoor
    case smoke
    case fire
    case unavailableStairwell
    case unavailableElevator
    case crowding
    case other

    var displayName: String {
        switch self {
        case .blockedHallway: return "Hallway blocked"
        case .lockedDoor: return "Door locked"
        case .smoke: return "Smoke ahead"
        case .fire: return "Fire ahead"
        case .unavailableStairwell: return "Stairwell unavailable"
        case .unavailableElevator: return "Elevator unavailable"
        case .crowding: return "Crowding ahead"
        case .other: return "Other problem"
        }
    }

    /// What routing may do with a segment carrying this hazard.
    ///
    /// Some conditions remove a segment outright; others make it expensive but
    /// still usable when nothing better exists. This is the only place that
    /// decision is made — `RouteEdge.availability` and the router both read it,
    /// so the two can never disagree.
    func availability(severity: Int) -> EdgeAvailability {
        let clamped = Double(max(1, min(5, severity)))
        switch self {
        case .blockedHallway, .lockedDoor, .fire, .unavailableStairwell, .unavailableElevator:
            return .unavailable
        case .smoke, .other:
            return .discouraged(costMultiplier: 1 + clamped * 0.6)
        case .crowding:
            // Crowding slows people down; it never makes a corridor impossible.
            return .discouraged(costMultiplier: 1 + clamped * 0.35)
        }
    }

    /// Whether this hazard makes the segment impassable outright.
    var blocksTravel: Bool { availability(severity: 3) == .unavailable }
}

/// What the router may do with one segment right now.
///
/// `unavailable` removes the edge from the search space entirely; it is never
/// expressed as a large finite cost that a desperate search could still pick.
enum EdgeAvailability: Equatable {
    case available
    case discouraged(costMultiplier: Double)
    case unavailable

    var costMultiplier: Double {
        switch self {
        case .available: return 1
        case .discouraged(let multiplier): return multiplier
        case .unavailable: return .infinity
        }
    }
}

struct RouteHazard: Identifiable, Codable, Hashable {
    let id: UUID
    var type: RouteHazardType
    var description: String
    /// 1 (minor) … 5 (severe).
    var severity: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        type: RouteHazardType,
        description: String = "",
        severity: Int = 3,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.description = description.isEmpty ? type.displayName : description
        self.severity = max(1, min(5, severity))
        self.createdAt = createdAt
    }
}

struct RouteEdge: Identifiable, Codable, Hashable {
    let id: UUID
    let fromNodeID: UUID
    let toNodeID: UUID
    var distanceMeters: Double
    var isBidirectional: Bool
    var isBlocked: Bool
    var accessibility: EdgeAccessibility
    var hazard: RouteHazard?
    /// Set only by the live overlay when an administrator publishes
    /// `restricted`. Optional so maps saved before this existed still decode.
    var restrictionSeverity: Int?

    init(
        id: UUID = UUID(),
        fromNodeID: UUID,
        toNodeID: UUID,
        distanceMeters: Double,
        isBidirectional: Bool = true,
        isBlocked: Bool = false,
        accessibility: EdgeAccessibility = .standard,
        hazard: RouteHazard? = nil,
        restrictionSeverity: Int? = nil
    ) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.distanceMeters = distanceMeters
        self.isBidirectional = isBidirectional
        self.isBlocked = isBlocked
        self.accessibility = accessibility
        self.hazard = hazard
        self.restrictionSeverity = restrictionSeverity
    }

    /// The one answer to "can the router use this, and at what cost".
    ///
    /// An administrator's *status* decides whether a segment is passable; the
    /// hazard type only sizes the penalty. Publishing `restricted` therefore
    /// never removes the segment, even when the hazard described would on its
    /// own — turning a stated restriction into a hard block would be putting
    /// words in the administrator's mouth.
    var availability: EdgeAvailability {
        if isBlocked { return .unavailable }
        if let restrictionSeverity {
            let described = (hazard?.type ?? .other).availability(severity: restrictionSeverity)
            if case .discouraged(let multiplier) = described {
                return .discouraged(costMultiplier: multiplier)
            }
            // A hazard that would normally close the segment, published only as
            // a restriction: usable, but a genuine last resort.
            return .discouraged(costMultiplier: 6 + Double(max(1, min(5, restrictionSeverity))) * 2)
        }
        guard let hazard else { return .available }
        return hazard.type.availability(severity: hazard.severity)
    }

    /// True when travel is impossible — either explicitly blocked or carrying
    /// a hazard that prevents passage.
    var isImpassable: Bool { availability == .unavailable }

    /// Multiplier applied for non-blocking hazards (e.g. light smoke).
    var hazardPenalty: Double {
        let multiplier = availability.costMultiplier
        return multiplier.isFinite ? multiplier : 1
    }

    func other(than nodeID: UUID) -> UUID? {
        if nodeID == fromNodeID { return toNodeID }
        if nodeID == toNodeID { return isBidirectional ? fromNodeID : nil }
        return nil
    }
}
