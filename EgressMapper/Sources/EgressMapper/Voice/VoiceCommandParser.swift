import Foundation

enum NavigationProfileChange: Equatable {
    case avoidStairs
    case requireWheelchairAccessible
    case avoidElevators
    case clearConstraints

    var description: String {
        switch self {
        case .avoidStairs: return "avoid stairs"
        case .requireWheelchairAccessible: return "wheelchair-accessible route"
        case .avoidElevators: return "avoid elevators"
        case .clearConstraints: return "standard route"
        }
    }

    func apply(to profile: NavigationProfile) -> NavigationProfile {
        var updated = profile
        switch self {
        case .avoidStairs:
            updated.avoidStairs = true
        case .requireWheelchairAccessible:
            updated.requireWheelchairAccessible = true
            updated.avoidStairs = true
        case .avoidElevators:
            updated.avoidElevators = true
        case .clearConstraints:
            updated.avoidStairs = false
            updated.requireWheelchairAccessible = false
            updated.avoidElevators = false
        }
        return updated
    }
}

enum EmergencyVoiceCommand: Equatable {
    case reportHazard(type: RouteHazardType, targetHint: String?)
    case updateAccessibility(NavigationProfileChange)
    case requestAlternativeExit
    case unknown(transcript: String)

    /// Commands that change the graph must always be confirmed first.
    var requiresConfirmation: Bool {
        if case .reportHazard = self { return true }
        return false
    }
}

/// Deterministic keyword parsing — no language model is involved. An uncertain
/// transcript resolves to `.unknown` rather than a guess, because a wrong guess
/// could block the only usable corridor.
enum VoiceCommandParser {

    static func parse(_ transcript: String) -> EmergencyVoiceCommand {
        let t = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return .unknown(transcript: transcript) }

        // Accessibility is checked first: "I can't use stairs" is a statement
        // about the user, not a report that the stairs are blocked.
        if let change = accessibilityChange(in: t) {
            return .updateAccessibility(change)
        }

        if contains(t, ["another exit", "different exit", "other exit", "alternative exit", "somewhere else"]) {
            return .requestAlternativeExit
        }

        if let hazard = hazardType(in: t) {
            return .reportHazard(type: hazard, targetHint: targetHint(in: t))
        }

        return .unknown(transcript: transcript)
    }

    // MARK: - Accessibility

    static func accessibilityChange(in t: String) -> NavigationProfileChange? {
        if contains(t, ["wheelchair", "accessible route", "step free", "step-free"]) {
            return .requireWheelchairAccessible
        }
        // Only a first-person inability, not "the stairs are blocked".
        if contains(t, ["i can't use stairs", "i cannot use stairs", "i can't use the stairs",
                        "i cannot use the stairs", "can't do stairs", "can't take stairs",
                        "no stairs", "avoid stairs", "without stairs"]) {
            return .avoidStairs
        }
        if contains(t, ["i can't use the elevator", "i cannot use the elevator",
                        "avoid elevator", "avoid elevators", "no elevator", "not the elevator"]) {
            return .avoidElevators
        }
        if contains(t, ["standard route", "normal route", "clear restrictions", "remove restrictions"]) {
            return .clearConstraints
        }
        return nil
    }

    // MARK: - Hazards

    static func hazardType(in t: String) -> RouteHazardType? {
        if contains(t, ["fire", "flames", "burning"]) { return .fire }
        if contains(t, ["smoke", "smoky"]) { return .smoke }

        let unusable = ["blocked", "closed", "not working", "isn't working", "is not working",
                        "out of order", "broken", "unavailable", "can't get through",
                        "cannot get through", "won't open", "jammed", "stuck"]

        if contains(t, ["door"]) {
            if contains(t, ["locked"]) { return .lockedDoor }
            if contains(t, unusable) { return .lockedDoor }
        }
        if contains(t, ["elevator", "lift"]), contains(t, unusable) { return .unavailableElevator }
        if contains(t, ["stair", "stairs", "stairwell"]), contains(t, unusable) { return .unavailableStairwell }
        if contains(t, ["hallway", "corridor", "hall", "way", "path", "route", "ahead"]),
           contains(t, unusable) { return .blockedHallway }
        if contains(t, ["blocked"]) { return .blockedHallway }
        return nil
    }

    /// A rough location phrase, surfaced to the user rather than acted on.
    static func targetHint(in t: String) -> String? {
        for hint in ["ahead", "in front of me", "behind me", "to my left", "to my right",
                     "east", "west", "north", "south", "upstairs", "downstairs"] {
            if t.contains(hint) { return hint }
        }
        return nil
    }

    private static func contains(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
