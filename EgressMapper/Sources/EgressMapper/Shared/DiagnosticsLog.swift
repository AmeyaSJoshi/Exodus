import Foundation
import os

/// Ring-buffered technical log, kept separate from user-facing error text.
/// Exportable via the share sheet so device-only AR failures can be reported.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    private let logger = Logger(subsystem: "com.egress.mapper", category: "diagnostics")
    private let queue = DispatchQueue(label: "com.egress.mapper.diagnostics")
    private var entries: [String] = []
    private let limit = 800

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ message: String) {
        let line = "[\(Self.stamp.string(from: Date()))] \(message)"
        logger.debug("\(message, privacy: .public)")
        queue.async {
            self.entries.append(line)
            if self.entries.count > self.limit {
                self.entries.removeFirst(self.entries.count - self.limit)
            }
        }
    }

    var text: String {
        queue.sync { entries.joined(separator: "\n") }
    }

    func clear() {
        queue.async { self.entries.removeAll() }
    }

    /// Writes the log to a temp file for `ShareLink`.
    func exportFile() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("egress-diagnostics-\(Int(Date().timeIntervalSince1970)).txt")
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
