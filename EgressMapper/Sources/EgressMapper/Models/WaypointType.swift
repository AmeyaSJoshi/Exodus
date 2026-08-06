import Foundation
import SwiftUI

enum WaypointType: String, Codable, CaseIterable, Identifiable, Hashable {
    case room
    case intersection
    case stairwell
    case elevator
    case exit
    case refugeArea

    var id: String { rawValue }

    var title: String {
        switch self {
        case .room: return "Room"
        case .intersection: return "Intersection"
        case .stairwell: return "Stairwell"
        case .elevator: return "Elevator"
        case .exit: return "Exit"
        case .refugeArea: return "Refuge"
        }
    }

    var symbolName: String {
        switch self {
        case .room: return "door.left.hand.closed"
        case .intersection: return "arrow.triangle.branch"
        case .stairwell: return "figure.stairs"
        case .elevator: return "arrow.up.arrow.down.square"
        case .exit: return "figure.run.square.stack"
        case .refugeArea: return "shield.lefthalf.filled"
        }
    }

    var tint: Color {
        switch self {
        case .room: return .blue
        case .intersection: return .orange
        case .stairwell: return .purple
        case .elevator: return .teal
        case .exit: return .green
        case .refugeArea: return .mint
        }
    }

    var uiColor: UIColor {
        switch self {
        case .room: return .systemBlue
        case .intersection: return .systemOrange
        case .stairwell: return .systemPurple
        case .elevator: return .systemTeal
        case .exit: return .systemGreen
        case .refugeArea: return .systemMint
        }
    }

    /// Only these can be picked as a navigation destination in v1.
    var isDestination: Bool { self == .exit }

    var defaultNamePrefix: String {
        switch self {
        case .room: return "Room"
        case .intersection: return "Intersection"
        case .stairwell: return "Stairwell"
        case .elevator: return "Elevator"
        case .exit: return "Exit"
        case .refugeArea: return "Refuge Area"
        }
    }
}
