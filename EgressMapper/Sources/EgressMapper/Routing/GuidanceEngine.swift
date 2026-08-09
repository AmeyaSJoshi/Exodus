import Foundation
import simd

/// Pure route-following logic: which leg the user is on, how far to the next
/// waypoint, and what to say. Kept free of ARKit so it is unit testable.
struct GuidanceEngine {
    enum Turn: String, Equatable {
        case straight = "Continue forward."
        case left = "Turn left."
        case right = "Turn right."
        case slightLeft = "Bear left."
        case slightRight = "Bear right."
        case around = "Turn around."
    }

    struct Update: Equatable {
        var legIndex: Int
        var nextNode: RouteNode?
        var distanceToNext: Double
        var remainingDistance: Double
        var instruction: String
        var arrived: Bool
    }

    let route: [RouteNode]
    /// How close counts as "reached this waypoint".
    var arrivalRadius: Double = 1.5

    private(set) var legIndex: Int = 0

    init(route: [RouteNode], arrivalRadius: Double = 1.5) {
        self.route = route
        self.arrivalRadius = arrivalRadius
    }

    var isEmpty: Bool { route.count < 2 }

    /// Advances the leg cursor if the user has reached the next waypoint.
    mutating func update(position: SIMD3<Float>) -> Update {
        guard !route.isEmpty else {
            return Update(legIndex: 0, nextNode: nil, distanceToNext: 0,
                          remainingDistance: 0, instruction: "No route.", arrived: false)
        }

        let here = MapPoint(projecting: position)

        while legIndex < route.count - 1 {
            let target = route[legIndex + 1]
            if here.distance(to: target.mapPoint) <= arrivalRadius {
                legIndex += 1
            } else {
                break
            }
        }

        let arrived = legIndex >= route.count - 1
        if arrived {
            return Update(
                legIndex: legIndex,
                nextNode: route.last,
                distanceToNext: 0,
                remainingDistance: 0,
                instruction: "\(route.last?.name ?? "Destination") reached.",
                arrived: true
            )
        }

        let next = route[legIndex + 1]
        let distance = here.distance(to: next.mapPoint)
        let remaining = distance + Self.pathLength(Array(route[(legIndex + 1)...]))

        return Update(
            legIndex: legIndex,
            nextNode: next,
            distanceToNext: distance,
            remainingDistance: remaining,
            instruction: Self.instruction(for: route, legIndex: legIndex, distance: distance),
            arrived: false
        )
    }

    static func pathLength(_ waypoints: [RouteNode]) -> Double {
        guard waypoints.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1..<waypoints.count {
            sum += waypoints[i].mapPoint.distance(to: waypoints[i - 1].mapPoint)
        }
        return sum
    }

    static func instruction(for route: [RouteNode], legIndex: Int, distance: Double) -> String {
        guard legIndex + 1 < route.count else { return "Destination reached." }
        let next = route[legIndex + 1]
        let metres = Int(distance.rounded())

        // Announce the manoeuvre awaiting the user at the next waypoint.
        if legIndex + 2 < route.count {
            let after = route[legIndex + 2]
            let turn = turnDirection(
                from: route[legIndex].mapPoint,
                via: next.mapPoint,
                to: after.mapPoint
            )
            if distance < 4 {
                return "\(turn.rawValue) \(destinationPhrase(next))"
            }
            return "Continue \(metres) m to \(next.name)."
        }

        if distance < 3 { return "\(destinationPhrase(next))" }
        return "Continue \(metres) m to \(next.name)."
    }

    static func destinationPhrase(_ w: RouteNode) -> String {
        switch w.type {
        case .exit: return "Exit ahead — \(w.name)."
        case .stairwell: return "Proceed to \(w.name)."
        case .elevator: return "Proceed to \(w.name)."
        case .intersection, .hallwayPoint: return "At \(w.name)."
        case .room: return "Arrive at \(w.name)."
        case .refugeArea: return "Shelter at \(w.name) — this is an area of refuge."
        case .temporaryStart: return "Continue from your location."
        }
    }

    static func turnDirection(from a: MapPoint, via b: MapPoint, to c: MapPoint) -> Turn {
        let inbound = atan2(b.y - a.y, b.x - a.x)
        let outbound = atan2(c.y - b.y, c.x - b.x)
        var delta = (outbound - inbound) * 180 / .pi
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }

        let magnitude = abs(delta)
        if magnitude < 20 { return .straight }
        if magnitude > 150 { return .around }
        // Map space is X/Z with Z increasing "into" the room, so a positive
        // delta corresponds to a rightward turn from the walker's view.
        if magnitude > 65 { return delta > 0 ? .right : .left }
        return delta > 0 ? .slightRight : .slightLeft
    }
}
