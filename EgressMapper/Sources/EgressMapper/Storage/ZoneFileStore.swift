import Foundation
import ARKit
import UIKit

enum ZoneStoreError: LocalizedError {
    case worldMapUnarchiveFailed
    case worldMapMissing
    case zoneMissing

    var errorDescription: String? {
        switch self {
        case .worldMapUnarchiveFailed: return "This zone's world map is corrupted and cannot be loaded."
        case .worldMapMissing: return "This zone has no saved world map. Re-map the zone to enable relocalization."
        case .zoneMissing: return "This zone's metadata is missing or unreadable."
        }
    }
}

/// On-disk layout:
/// Application Support/Zones/<uuid>/{zone,waypoints,path,alignment}.json,
///                                  worldmap.arexperience, reference.jpg, floorplan.jpg
struct ZoneFileStore {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("Zones", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func ensureDirectory(for id: UUID) throws {
        try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
    }

    func url(_ id: UUID, _ file: String) -> URL {
        directory(for: id).appendingPathComponent(file)
    }

    // MARK: - Codable helpers

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func writeJSON<T: Encodable>(_ value: T, to fileURL: URL) throws {
        let data = try Self.encoder.encode(value)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Returns nil rather than throwing when a file is absent or unreadable —
    /// one broken sidecar must not make the whole zone disappear.
    func readJSON<T: Decodable>(_ type: T.Type, from fileURL: URL) -> T? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    // MARK: - Zone metadata

    func saveZone(_ zone: MappingZone) throws {
        try ensureDirectory(for: zone.id)
        try writeJSON(zone, to: url(zone.id, "zone.json"))
    }

    func loadZone(_ id: UUID) -> MappingZone? {
        readJSON(MappingZone.self, from: url(id, "zone.json"))
    }

    func listZones() -> [MappingZone] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { loadZone($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func deleteZone(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory(for: id))
    }

    // MARK: - Waypoints & path

    func saveWaypoints(_ waypoints: [Waypoint], zoneID: UUID) throws {
        try ensureDirectory(for: zoneID)
        try writeJSON(waypoints, to: url(zoneID, "waypoints.json"))
    }

    func loadWaypoints(_ zoneID: UUID) -> [Waypoint] {
        readJSON([Waypoint].self, from: url(zoneID, "waypoints.json")) ?? []
    }

    func savePath(_ path: RoutePath, zoneID: UUID) throws {
        try ensureDirectory(for: zoneID)
        try writeJSON(path, to: url(zoneID, "path.json"))
    }

    func loadPath(_ zoneID: UUID) -> RoutePath {
        readJSON(RoutePath.self, from: url(zoneID, "path.json")) ?? RoutePath()
    }

    // MARK: - World map

    func saveWorldMap(_ map: ARWorldMap, zoneID: UUID) throws {
        try ensureDirectory(for: zoneID)
        let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
        try data.write(to: url(zoneID, "worldmap.arexperience"), options: .atomic)
    }

    func loadWorldMap(_ zoneID: UUID) throws -> ARWorldMap {
        let fileURL = url(zoneID, "worldmap.arexperience")
        guard let data = try? Data(contentsOf: fileURL) else { throw ZoneStoreError.worldMapMissing }
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw ZoneStoreError.worldMapUnarchiveFailed
        }
        return map
    }

    func hasWorldMap(_ zoneID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(zoneID, "worldmap.arexperience").path)
    }

    // MARK: - Images

    func saveReferenceImage(_ image: UIImage, zoneID: UUID) throws {
        try ensureDirectory(for: zoneID)
        guard let data = image.jpegData(compressionQuality: 0.7) else { return }
        try data.write(to: url(zoneID, "reference.jpg"), options: .atomic)
    }

    func loadReferenceImage(_ zoneID: UUID) -> UIImage? {
        UIImage(contentsOfFile: url(zoneID, "reference.jpg").path)
    }

    // MARK: - Route graph (derived; safe to regenerate)

    func saveGraph(_ graph: BuildingGraph, zoneID: UUID) throws {
        try ensureDirectory(for: zoneID)
        try writeJSON(graph, to: url(zoneID, "graph.json"))
    }

    /// A corrupt or stale graph returns nil so the caller regenerates it from
    /// `waypoints.json` — those source files are never touched.
    func loadGraph(_ zoneID: UUID) -> BuildingGraph? {
        readJSON(BuildingGraph.self, from: url(zoneID, "graph.json"))
    }

    // MARK: - Active hazards (separate from the permanent graph)

    func saveHazards(_ hazards: ActiveHazards, zoneID: UUID) throws {
        try ensureDirectory(for: zoneID)
        try writeJSON(hazards, to: url(zoneID, "hazards.json"))
    }

    func loadHazards(_ zoneID: UUID) -> ActiveHazards {
        readJSON(ActiveHazards.self, from: url(zoneID, "hazards.json")) ?? ActiveHazards(zoneID: zoneID)
    }

    func clearHazards(_ zoneID: UUID) throws {
        let fileURL = url(zoneID, "hazards.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Navigation profile (device-wide)

    func saveProfile(_ profile: NavigationProfile) throws {
        try writeJSON(profile, to: root.appendingPathComponent("profile.json"))
    }

    func loadProfile() -> NavigationProfile {
        readJSON(NavigationProfile.self, from: root.appendingPathComponent("profile.json")) ?? .standard
    }

    func saveFloorPlanImage(_ image: UIImage, zoneID: UUID) throws {
        try ensureDirectory(for: zoneID)
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try data.write(to: url(zoneID, "floorplan.jpg"), options: .atomic)
    }

    func loadFloorPlanImage(_ zoneID: UUID) -> UIImage? {
        UIImage(contentsOfFile: url(zoneID, "floorplan.jpg").path)
    }

    func saveAlignment(_ alignment: FloorPlanAlignment, zoneID: UUID) throws {
        try ensureDirectory(for: zoneID)
        try writeJSON(alignment, to: url(zoneID, "alignment.json"))
    }

    func loadAlignment(_ zoneID: UUID) -> FloorPlanAlignment? {
        readJSON(FloorPlanAlignment.self, from: url(zoneID, "alignment.json"))
    }
}
