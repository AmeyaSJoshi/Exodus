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
        }
    }
}

struct RouteNode: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var type: RouteNodeType
    var position: CodableTransform
    var zoneID: UUID

    init(id: UUID = UUID(), name: String, type: RouteNodeType, position: CodableTransform, zoneID: UUID) {
        self.id = id
        self.name = name
        self.type = type
        self.position = position
        self.zoneID = zoneID
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
    case other

    var displayName: String {
        switch self {
        case .blockedHallway: return "Hallway blocked"
        case .lockedDoor: return "Door locked"
        case .smoke: return "Smoke ahead"
        case .fire: return "Fire ahead"
        case .unavailableStairwell: return "Stairwell unavailable"
        case .unavailableElevator: return "Elevator unavailable"
        case .other: return "Other problem"
        }
    }

    /// Whether this hazard makes the segment impassable outright.
    var blocksTravel: Bool {
        switch self {
        case .blockedHallway, .lockedDoor, .fire, .unavailableStairwell, .unavailableElevator:
            return true
        case .smoke, .other:
            return false   // passable but heavily penalised
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

    init(
        id: UUID = UUID(),
        fromNodeID: UUID,
        toNodeID: UUID,
        distanceMeters: Double,
        isBidirectional: Bool = true,
        isBlocked: Bool = false,
        accessibility: EdgeAccessibility = .standard,
        hazard: RouteHazard? = nil
    ) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.distanceMeters = distanceMeters
        self.isBidirectional = isBidirectional
        self.isBlocked = isBlocked
        self.accessibility = accessibility
        self.hazard = hazard
    }

    /// True when travel is impossible — either explicitly blocked or carrying
    /// a hazard that prevents passage.
    var isImpassable: Bool {
        isBlocked || (hazard?.type.blocksTravel ?? false)
    }

    /// Multiplier applied for non-blocking hazards (e.g. light smoke).
    var hazardPenalty: Double {
        guard let hazard, !hazard.type.blocksTravel else { return 1 }
        return 1 + Double(hazard.severity) * 0.6
    }

    func other(than nodeID: UUID) -> UUID? {
        if nodeID == fromNodeID { return toNodeID }
        if nodeID == toNodeID { return isBidirectional ? fromNodeID : nil }
        return nil
    }
}
