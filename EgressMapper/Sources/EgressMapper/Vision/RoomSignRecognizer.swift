import Foundation
import Vision
import CoreVideo

struct RecognizedSign: Equatable, Identifiable {
    var id: String { text }
    var text: String
    var suggestedName: String
    var type: WaypointType
    var confidence: Float
}

/// Throttled, off-main-thread text recognition for room numbers and exit signs.
/// Purely advisory — nothing is ever added without administrator confirmation.
final class RoomSignRecognizer: @unchecked Sendable {

    /// Minimum gap between OCR passes. Frequent OCR competes with ARKit for
    /// the GPU and heats the device, which degrades tracking.
    var interval: TimeInterval = 1.5
    var minimumConfidence: Float = 0.4
    /// Do not re-suggest the same sign within this window.
    var suppressionWindow: TimeInterval = 45

    private let queue = DispatchQueue(label: "com.egress.mapper.ocr", qos: .utility)
    private var lastRun: Date = .distantPast
    private var recentlySuggested: [String: Date] = [:]
    private var isRunning = false

    var isEnabled = true

    /// Call with each AR frame's pixel buffer; internally rate-limited.
    func process(
        pixelBuffer: CVPixelBuffer,
        completion: @escaping (RecognizedSign) -> Void
    ) {
        guard isEnabled, !isRunning else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRun) >= interval else { return }
        lastRun = now
        isRunning = true

        queue.async { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }

            let request = VNRecognizeTextRequest()
            // .fast keeps latency low enough not to disturb tracking.
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            do {
                try handler.perform([request])
            } catch {
                DiagnosticsLog.shared.log("OCR failed: \(error.localizedDescription)")
                return
            }

            guard let observations = request.results else { return }
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                guard candidate.confidence >= self.minimumConfidence else { continue }
                guard var sign = Self.classify(candidate.string) else { continue }
                sign.confidence = candidate.confidence

                if let last = self.recentlySuggested[sign.text],
                   Date().timeIntervalSince(last) < self.suppressionWindow {
                    continue
                }
                self.recentlySuggested[sign.text] = Date()
                DiagnosticsLog.shared.log("OCR suggested \(sign.text) -> \(sign.type.rawValue)")

                DispatchQueue.main.async { completion(sign) }
                return
            }
        }
    }

    func reset() {
        recentlySuggested.removeAll()
        lastRun = .distantPast
    }

    // MARK: - Classification (pure, unit tested)

    static func classify(_ raw: String) -> RecognizedSign? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 24 else { return nil }
        let upper = text.uppercased()

        // Exit signage
        if upper == "EXIT" || upper.hasPrefix("EXIT ") || upper.hasSuffix(" EXIT") {
            return RecognizedSign(text: text, suggestedName: text.capitalized, type: .exit, confidence: 0)
        }

        // Stairwell, e.g. "STAIR A", "STAIRWELL B"
        if upper.hasPrefix("STAIR") {
            return RecognizedSign(text: text, suggestedName: text.capitalized, type: .stairwell, confidence: 0)
        }

        if upper.hasPrefix("ELEVATOR") || upper == "LIFT" {
            return RecognizedSign(text: text, suggestedName: text.capitalized, type: .elevator, confidence: 0)
        }

        // "Room 214", "Rm 214", "RM. 214"
        if let number = matchRoomNumber(upper) {
            return RecognizedSign(text: text, suggestedName: "Room \(number)", type: .room, confidence: 0)
        }

        return nil
    }

    static func matchRoomNumber(_ upper: String) -> String? {
        let stripped = upper
            .replacingOccurrences(of: "ROOM", with: "")
            .replacingOccurrences(of: "RM.", with: "")
            .replacingOccurrences(of: "RM", with: "")
            .trimmingCharacters(in: .whitespaces)

        // A bare 2–4 digit number, optionally with a single trailing letter.
        let pattern = #"^[A-Z]?\d{2,4}[A-Z]?$"#
        guard stripped.range(of: pattern, options: .regularExpression) != nil else { return nil }
        // Reject values that are almost certainly not room numbers (years, times).
        if stripped.count == 4, let n = Int(stripped), (1900...2100).contains(n) { return nil }
        return stripped
    }
}
