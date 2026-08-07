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

/// One saved photograph of a mapped zone, taken from a stated direction.
/// Several of these per zone is what lets relocalization succeed from more
/// than the single angle the zone was originally captured from.
struct ZoneReferenceView: Codable, Hashable, Identifiable {
    var id: UUID
    var fileName: String
    /// Free text shown to the user: "facing the stairwell", "from the lobby".
    var viewpoint: String
    var capturedAt: Date

    init(
        id: UUID = UUID(),
        fileName: String,
        viewpoint: String,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.viewpoint = viewpoint
        self.capturedAt = capturedAt
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

    /// Canonical directory for a zone: uppercase, matching `UUID.uuidString`.
    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The directory actually holding this zone. Falls back to a differently
    /// cased name if one exists, so a zone stays readable on a case-sensitive
    /// volume where the canonical path would miss.
    func existingDirectory(for id: UUID) -> URL? {
        let canonical = directory(for: id)
        if FileManager.default.fileExists(atPath: canonical.path) { return canonical }
        return zoneDirectories()[id]
    }

    private func ensureDirectory(for id: UUID) throws {
        try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
    }

    func url(_ id: UUID, _ file: String) -> URL {
        (existingDirectory(for: id) ?? directory(for: id)).appendingPathComponent(file)
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

    // MARK: - Atomic commit
    //
    // Finishing a mapping walk used to write each file straight into the final
    // zone directory, with `zone.json` written last. Anything that threw part
    // way left a directory holding a world map but no metadata — and a zone
    // with no `zone.json` is invisible to `listZones`, so the map the user had
    // just recorded silently vanished. Everything is now staged, read back,
    // and only then moved into place.

    /// What a commit produced, so a failure can name the component that broke
    /// rather than reporting a generic error.
    struct CommitResult: Equatable {
        var zoneID: UUID
        var wroteWorldMap: Bool
        var wroteReferenceImage: Bool
        var waypointCount: Int
        var pathPoints: Int
    }

    enum CommitError: LocalizedError, Equatable {
        case write(component: String, detail: String)
        case validation(component: String)
        case replace(String)

        var errorDescription: String? {
            switch self {
            case .write(let component, let detail):
                return "Could not write \(component): \(detail). Your previous saved copy is untouched."
            case .validation(let component):
                return "\(component) could not be read back after saving, so the map was not saved. Your previous saved copy is untouched."
            case .replace(let detail):
                return "Could not finalise the saved map: \(detail). Your previous saved copy is untouched."
            }
        }

        /// The specific thing that failed, for the retry UI.
        var component: String {
            switch self {
            case .write(let component, _), .validation(let component): return component
            case .replace: return "Zone directory"
            }
        }
    }

    /// Writes a complete zone atomically.
    ///
    /// Staged into a sibling directory, validated by reading every artifact
    /// back, then swapped in with a directory move. A failure at any point
    /// leaves the previously saved zone exactly as it was.
    @discardableResult
    func commitZone(
        _ zone: MappingZone,
        waypoints: [Waypoint],
        path: RoutePath,
        worldMap: Data?,
        graph: BuildingGraph? = nil,
        referenceImage: Data? = nil,
        referenceViews: [(view: ZoneReferenceView, data: Data)] = []
    ) throws -> CommitResult {
        let fm = FileManager.default
        let staging = root.appendingPathComponent(
            ".staging-\(zone.id.uuidString)-\(UUID().uuidString)", isDirectory: true
        )

        func stagedURL(_ name: String) -> URL { staging.appendingPathComponent(name) }
        func fail(_ error: CommitError) -> CommitError {
            try? fm.removeItem(at: staging)
            return error
        }

        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw CommitError.write(component: "Zone folder", detail: error.localizedDescription)
        }

        // 1. Write everything into staging.
        do {
            try writeJSON(zone, to: stagedURL("zone.json"))
        } catch {
            throw fail(.write(component: "Zone details", detail: error.localizedDescription))
        }
        do {
            try writeJSON(waypoints, to: stagedURL("waypoints.json"))
            try writeJSON(path, to: stagedURL("path.json"))
        } catch {
            throw fail(.write(component: "Waypoints", detail: error.localizedDescription))
        }
        if let graph {
            do {
                try writeJSON(graph, to: stagedURL("graph.json"))
            } catch {
                throw fail(.write(component: "Route graph", detail: error.localizedDescription))
            }
        }
        if let worldMap {
            do {
                try worldMap.write(to: stagedURL("worldmap.arexperience"), options: .atomic)
            } catch {
                throw fail(.write(component: "AR world map", detail: error.localizedDescription))
            }
        }
        if let referenceImage {
            do {
                try referenceImage.write(to: stagedURL("reference.jpg"), options: .atomic)
            } catch {
                throw fail(.write(component: "Reference image", detail: error.localizedDescription))
            }
        }
        if !referenceViews.isEmpty {
            do {
                for item in referenceViews {
                    try item.data.write(to: stagedURL(item.view.fileName), options: .atomic)
                }
                try writeJSON(referenceViews.map(\.view), to: stagedURL("references.json"))
            } catch {
                throw fail(.write(component: "Reference views", detail: error.localizedDescription))
            }
        }

        // 2. Read every artifact back before anything is promoted.
        guard let readBack = readJSON(MappingZone.self, from: stagedURL("zone.json")),
              readBack.id == zone.id else {
            throw fail(.validation(component: "Zone details"))
        }
        guard let storedWaypoints = readJSON([Waypoint].self, from: stagedURL("waypoints.json")),
              storedWaypoints.count == waypoints.count else {
            throw fail(.validation(component: "Waypoints"))
        }
        guard let storedPath = readJSON(RoutePath.self, from: stagedURL("path.json")) else {
            throw fail(.validation(component: "Recorded path"))
        }
        if let graph {
            guard let storedGraph = readJSON(BuildingGraph.self, from: stagedURL("graph.json")),
                  storedGraph.nodes.count == graph.nodes.count else {
                throw fail(.validation(component: "Route graph"))
            }
        }
        if let worldMap {
            // Byte-for-byte, and then that it still unarchives into an
            // ARWorldMap — a file that exists but cannot decode is worse than
            // no file, because the zone looks complete and fails later.
            guard let storedMap = try? Data(contentsOf: stagedURL("worldmap.arexperience")),
                  storedMap.count == worldMap.count else {
                throw fail(.validation(component: "AR world map"))
            }
            guard Self.worldMapDecodes(storedMap) else {
                throw fail(.validation(component: "AR world map"))
            }
        }

        // 3. Swap it in. The old directory is kept aside until the new one is
        //    safely in place, then removed.
        let destination = directory(for: zone.id)
        var retired: URL?
        if fm.fileExists(atPath: destination.path) {
            let aside = root.appendingPathComponent(
                ".retired-\(zone.id.uuidString)-\(UUID().uuidString)", isDirectory: true
            )
            do {
                try fm.moveItem(at: destination, to: aside)
                retired = aside
            } catch {
                throw fail(.replace(error.localizedDescription))
            }
        }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            // Put the previous version back rather than leaving nothing.
            if let retired { try? fm.moveItem(at: retired, to: destination) }
            throw fail(.replace(error.localizedDescription))
        }
        if let retired { try? fm.removeItem(at: retired) }

        return CommitResult(
            zoneID: zone.id,
            wroteWorldMap: worldMap != nil,
            wroteReferenceImage: referenceImage != nil,
            waypointCount: storedWaypoints.count,
            pathPoints: storedPath.count
        )
    }

    /// Overridable in tests, where a real `ARWorldMap` cannot be constructed.
    nonisolated(unsafe) static var worldMapDecodes: (Data) -> Bool = { data in
        (try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)) != nil
    }

    /// Removes leftover staging/retired directories from an interrupted save.
    /// They are prefixed with a dot and are never listed as zones, but there is
    /// no reason to keep them.
    func cleanUpInterruptedSaves() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".staging-")
            || entry.lastPathComponent.hasPrefix(".retired-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func loadZone(_ id: UUID) -> MappingZone? {
        readJSON(MappingZone.self, from: url(id, "zone.json"))
    }

    /// Zone directories present on disk, keyed by id. Directory names are
    /// written uppercase, but a name that differs only in case still resolves —
    /// the id is the identity, not the spelling.
    private func zoneDirectories() -> [UUID: URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var found: [UUID: URL] = [:]
        for entry in entries {
            let name = entry.lastPathComponent
            // Staging and retired leftovers are dot-prefixed and never zones.
            guard !name.hasPrefix("."), let id = UUID(uuidString: name) else { continue }
            found[id] = entry
        }
        return found
    }

    func listZones() -> [MappingZone] {
        scanZones().zones
    }

    /// Enumerates and decodes every zone exactly once, reporting both the
    /// usable zones and the damaged folders. Callers that need both must use
    /// this rather than calling `listZones` and `damagedZoneIDs` separately —
    /// that decoded every `zone.json` twice on every launch.
    ///
    /// Reads only `zone.json`. World maps, reference images and checksums are
    /// deliberately untouched: listing saved maps must not depend on the size
    /// of what was recorded.
    func scanZones() -> (zones: [MappingZone], damaged: [UUID]) {
        var zones: [MappingZone] = []
        var damaged: [UUID] = []
        for (id, _) in zoneDirectories() {
            if let zone = loadZone(id) { zones.append(zone) } else { damaged.append(id) }
        }
        return (
            zones.sorted { $0.updatedAt > $1.updatedAt },
            damaged.sorted { $0.uuidString < $1.uuidString }
        )
    }

    /// Zone directories that exist but whose metadata will not decode.
    ///
    /// Without this a corrupt zone is indistinguishable from one that was never
    /// saved: it simply drops out of the list. Callers surface it so the user
    /// sees "this map is damaged" rather than an unexplained empty screen.
    func damagedZoneIDs() -> [UUID] {
        scanZones().damaged
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

    // MARK: - Additional reference viewpoints
    //
    // Relocalizing only ever worked from the one angle the original
    // `reference.jpg` was shot from. Extra views are stored alongside it as
    // `reference-<uuid>.jpg`, indexed by `references.json`. The legacy file is
    // left exactly where it is, so every existing zone keeps working.

    func referenceViews(_ zoneID: UUID) -> [ZoneReferenceView] {
        var views = readJSON([ZoneReferenceView].self, from: url(zoneID, "references.json")) ?? []
        // Surface the original single image as an unlabelled viewpoint.
        if FileManager.default.fileExists(atPath: url(zoneID, "reference.jpg").path),
           !views.contains(where: { $0.fileName == "reference.jpg" }) {
            views.insert(
                ZoneReferenceView(fileName: "reference.jpg", viewpoint: "Original view"), at: 0
            )
        }
        return views
    }

    @discardableResult
    func addReferenceView(
        _ image: UIImage, viewpoint: String, zoneID: UUID
    ) throws -> ZoneReferenceView {
        try ensureDirectory(for: zoneID)
        let view = ZoneReferenceView(
            fileName: "reference-\(UUID().uuidString).jpg", viewpoint: viewpoint
        )
        guard let data = image.jpegData(compressionQuality: 0.75) else { return view }
        try data.write(to: url(zoneID, view.fileName), options: .atomic)

        var existing = readJSON([ZoneReferenceView].self, from: url(zoneID, "references.json")) ?? []
        existing.append(view)
        try writeJSON(existing, to: url(zoneID, "references.json"))
        return view
    }

    func referenceViewData(_ view: ZoneReferenceView, zoneID: UUID) -> Data? {
        try? Data(contentsOf: url(zoneID, view.fileName))
    }

    func referenceViewImage(_ view: ZoneReferenceView, zoneID: UUID) -> UIImage? {
        UIImage(contentsOfFile: url(zoneID, view.fileName).path)
    }

    func removeReferenceView(_ view: ZoneReferenceView, zoneID: UUID) throws {
        try? FileManager.default.removeItem(at: url(zoneID, view.fileName))
        let remaining = (readJSON([ZoneReferenceView].self, from: url(zoneID, "references.json")) ?? [])
            .filter { $0.id != view.id }
        try writeJSON(remaining, to: url(zoneID, "references.json"))
    }

    /// Raw bytes of the saved world map, for publication. Returns nil rather
    /// than throwing — a zone with no world map still publishes its graph.
    func worldMapData(_ zoneID: UUID) -> Data? {
        try? Data(contentsOf: url(zoneID, "worldmap.arexperience"))
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
