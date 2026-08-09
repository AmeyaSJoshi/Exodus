import Foundation

@Observable
final class ZoneRepository {
    private(set) var zones: [MappingZone] = []
    private(set) var isLoading = false
    var lastError: String?
    /// Zone folders on disk whose metadata will not decode. Surfaced in Saved
    /// Maps so a damaged map reads as damaged rather than silently vanishing.
    private(set) var damagedZoneIDs: [UUID] = []

    let store: ZoneFileStore

    init(store: ZoneFileStore = ZoneFileStore()) {
        self.store = store
    }

    @MainActor
    func refresh() async {
        isLoading = true
        let store = self.store
        // One pass. `listZones` and `damagedZoneIDs` each enumerated the
        // directory and decoded every `zone.json`, so a launch decoded all of
        // them twice.
        let result = await Task.detached(priority: .userInitiated) {
            store.scanZones()
        }.value
        zones = result.zones
        damagedZoneIDs = result.damaged
        if !result.damaged.isEmpty {
            DiagnosticsLog.shared.log("Damaged zone folders: \(result.damaged.count)")
        }
        isLoading = false
    }

    @MainActor
    func create(_ zone: MappingZone) async {
        let store = self.store
        do {
            try await Task.detached(priority: .userInitiated) { try store.saveZone(zone) }.value
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func upsert(_ zone: MappingZone) async {
        await create(zone)
    }

    @MainActor
    func delete(_ zone: MappingZone) async {
        let store = self.store
        let id = zone.id
        do {
            try await Task.detached(priority: .userInitiated) { try store.deleteZone(id) }.value
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func rename(_ zone: MappingZone, to newName: String) async {
        var updated = zone
        updated.zoneName = newName
        updated.updatedAt = Date()
        await upsert(updated)
    }

    /// Loads everything needed to navigate a zone. Returns nil when the zone
    /// is unusable (no waypoints or no world map).
    func loadBundle(_ zone: MappingZone) -> (waypoints: [Waypoint], path: RoutePath)? {
        let waypoints = store.loadWaypoints(zone.id)
        guard !waypoints.isEmpty else { return nil }
        return (waypoints, store.loadPath(zone.id))
    }

    /// Loads the routable graph for a zone, migrating from legacy waypoint
    /// data when needed. Never deletes or rewrites the source files.
    func graph(for zone: MappingZone) -> BuildingGraph? {
        let waypoints = store.loadWaypoints(zone.id)
        guard !waypoints.isEmpty else { return nil }
        let path = store.loadPath(zone.id)

        let resolved = GraphMigrator.resolve(
            stored: store.loadGraph(zone.id),
            zoneID: zone.id,
            waypoints: waypoints,
            path: path
        )
        if resolved.didMigrate {
            try? store.saveGraph(resolved.graph, zoneID: zone.id)
            DiagnosticsLog.shared.log("Migrated graph for zone \(zone.id) — \(resolved.graph.nodes.count) nodes")
        }
        return resolved.graph
    }

    /// Graph with any active hazards applied. The stored graph stays clean.
    func routableGraph(for zone: MappingZone) -> BuildingGraph? {
        guard let base = graph(for: zone) else { return nil }
        return base.applying(hazards: store.loadHazards(zone.id).hazards)
    }

    /// Zones grouped by campus › building › floor for the saved-zones list.
    var grouped: [(key: String, zones: [MappingZone])] {
        Dictionary(grouping: zones, by: { "\($0.campus) · \($0.building) · \($0.floor)" })
            .map { (key: $0.key, zones: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { $0.key < $1.key }
    }
}
