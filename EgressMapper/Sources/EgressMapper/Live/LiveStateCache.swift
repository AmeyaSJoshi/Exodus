import Foundation

/// Offline cache: the published graph and the last known building state.
/// An evacuation must not depend on the network being up.
struct LiveStateCache {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("LiveState", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func url(_ buildingID: UUID, _ name: String) -> URL {
        root.appendingPathComponent("\(buildingID.uuidString)-\(name)")
    }

    // MARK: - Graph

    func saveGraph(_ graph: BuildingGraph, buildingID: UUID) {
        guard let data = try? Self.encoder.encode(graph) else { return }
        try? data.write(to: url(buildingID, "graph.json"), options: .atomic)
    }

    func loadGraph(buildingID: UUID) -> BuildingGraph? {
        guard let data = try? Data(contentsOf: url(buildingID, "graph.json")) else { return nil }
        return try? Self.decoder.decode(BuildingGraph.self, from: data)
    }

    // MARK: - Snapshot

    func saveSnapshot(_ snapshot: BuildingStateSnapshot, buildingID: UUID) {
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        try? data.write(to: url(buildingID, "state.json"), options: .atomic)
    }

    /// Returns nil for a missing or corrupt cache — never throws, because a bad
    /// cache must not stop the app from starting.
    func loadSnapshot(buildingID: UUID) -> BuildingStateSnapshot? {
        guard let data = try? Data(contentsOf: url(buildingID, "state.json")) else { return nil }
        return try? Self.decoder.decode(BuildingStateSnapshot.self, from: data)
    }

    func clear(buildingID: UUID) {
        try? FileManager.default.removeItem(at: url(buildingID, "graph.json"))
        try? FileManager.default.removeItem(at: url(buildingID, "state.json"))
    }
}
