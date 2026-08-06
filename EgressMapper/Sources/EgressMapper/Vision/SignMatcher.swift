import Foundation

/// Matches recognised sign text against the labels of a zone's graph nodes,
/// so a room number read off a door can act as a localization fallback.
/// Deliberately conservative — OCR is an aid, never an authority.
enum SignMatcher {

    struct Match: Equatable, Identifiable {
        var node: RouteNode
        var score: Double
        var matchedText: String
        var id: UUID { node.id }
    }

    /// Below this, a match is not offered to the user at all.
    static let minimumScore: Double = 0.6

    /// Strips label noise so "Rm. 214" and "Room 214" compare equal.
    static func normalize(_ raw: String) -> String {
        var s = raw.uppercased()
        for token in ["ROOM", "RM.", "RM", "STAIRWELL", "STAIR", "SUITE", "#"] {
            s = s.replacingOccurrences(of: token, with: " ")
        }
        s = s.replacingOccurrences(of: "[^A-Z0-9 ]", with: " ", options: .regularExpression)
        return s.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The digit run inside a label, if any — the strongest signal for rooms.
    static func numericToken(_ raw: String) -> String? {
        let match = raw.range(of: "[0-9]{2,4}[A-Za-z]?", options: .regularExpression)
        return match.map { String(raw[$0]).uppercased() }
    }

    static func score(text: String, against node: RouteNode) -> Double {
        let a = normalize(text)
        let b = normalize(node.name)
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        if a == b { return 1.0 }

        // A shared room number is decisive: "214" vs "Room 214".
        if let na = numericToken(text), let nb = numericToken(node.name), na == nb {
            return 0.95
        }

        // One label containing the other, e.g. "STAIR A" vs "A".
        if b.contains(a) || a.contains(b) {
            let ratio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
            return 0.6 + 0.3 * ratio
        }

        // Token overlap for multi-word landmarks.
        let ta = Set(a.split(separator: " ").map(String.init))
        let tb = Set(b.split(separator: " ").map(String.init))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let shared = ta.intersection(tb).count
        guard shared > 0 else { return 0 }
        return 0.5 * Double(shared) / Double(max(ta.count, tb.count))
    }

    /// Ranked candidate matches above the confidence floor.
    static func matches(text: String, nodes: [RouteNode], limit: Int = 3) -> [Match] {
        nodes
            .filter { $0.type != .temporaryStart }
            .map { Match(node: $0, score: score(text: text, against: $0), matchedText: text) }
            .filter { $0.score >= minimumScore }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }
}
