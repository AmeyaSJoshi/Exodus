import Foundation
import Supabase

/// Talks to Supabase. Holds no routing logic — it fetches building condition and
/// publishes changes; the existing `ShortestPathService` does all the routing.
@Observable
@MainActor
final class SupabaseBuildingService: BuildingStateService {

    private(set) var connection: ConnectionStatus = .offline
    private(set) var signedInEmail: String?
    private(set) var buildings: [RemoteBuilding] = []
    private(set) var overlay: LiveStateOverlay?
    private(set) var graph: BuildingGraph?
    private(set) var lastError: String?
    private(set) var usingCache = false
    private(set) var profile: UserProfile = .empty
    private(set) var catalog: [CatalogBuilding] = []
    /// Map version cached per building, so Saved Maps can show update state.
    private(set) var cachedVersions: [UUID: Int] = [:]

    /// Emitted when live state changes in a way the UI should react to.
    var onStateChanged: ((LiveEdgeState?) -> Void)?

    private var client: SupabaseClient?
    /// Exposed so map publishing reuses this authenticated session rather than
    /// creating a second client.
    var currentClient: SupabaseClient? { client }
    private var channel: RealtimeChannelV2?
    private var listenTask: Task<Void, Never>?
    private var currentBuildingID: UUID?
    private let cache: LiveStateCache

    init(cache: LiveStateCache = LiveStateCache()) {
        self.cache = cache
    }

    var revision: Int64 { overlay?.revision ?? 0 }

    // MARK: - Connection

    func configure(_ config: BackendConfig) throws {
        guard config.isConfigured, let url = URL(string: config.url) else {
            throw BackendError.notConfigured
        }
        client = SupabaseClient(supabaseURL: url, supabaseKey: config.anonKey)
        config.save()
    }

    func signIn(email: String, password: String) async throws {
        guard let client else { throw BackendError.notConfigured }
        let session = try await client.auth.signIn(email: email, password: password)
        signedInEmail = session.user.email
        lastError = nil
    }

    /// Role and organization come from the server, never from user input.
    func loadProfile() async throws {
        guard let client else { throw BackendError.notConfigured }
        profile = try await client.rpc("my_profile").execute().value
    }

    /// Every published building in the caller's organization (plus drafts if
    /// they are an administrator).
    func loadCatalog() async throws {
        guard let client else { throw BackendError.notConfigured }
        catalog = try await client.rpc("organization_buildings").execute().value
        cachedVersions = cache.loadVersions()
    }

    struct NewBuilding: Encodable {
        var p_name: String
        var p_address: String?
        var p_description: String?
    }

    /// Creates a building in the caller's own organization.
    @discardableResult
    func createBuilding(name: String, address: String?, description: String?) async throws -> CatalogBuilding {
        guard let client else { throw BackendError.notConfigured }
        let row: RemoteBuilding = try await client
            .rpc("create_building", params: NewBuilding(
                p_name: name,
                p_address: address?.isEmpty == true ? nil : address,
                p_description: description?.isEmpty == true ? nil : description
            ))
            .single()
            .execute()
            .value
        try await loadCatalog()
        return CatalogBuilding(
            id: row.id, name: row.name, address: row.address, description: nil,
            status: "draft", activeMapVersionID: nil, version: nil, publishedAt: nil,
            nodeCount: 0, artifactCount: 0
        )
    }

    /// Deletes a building and every version of its map for the whole
    /// organization. Storage objects go first: once the rows are gone their
    /// paths are unknown, and orphaned binaries would sit in the bucket
    /// forever. The RPC re-checks authorization server-side regardless.
    func deleteBuilding(id: UUID) async throws {
        guard let client else { throw BackendError.notConfigured }

        let objects = try? await client.storage
            .from(MapArtifactBucket.name)
            .list(path: id.uuidString)
        if let objects, !objects.isEmpty {
            // `list` is shallow, so recurse one level: paths are
            // <building>/<version>/<file>.
            var paths: [String] = []
            for entry in objects {
                let nested = try? await client.storage
                    .from(MapArtifactBucket.name)
                    .list(path: "\(id.uuidString)/\(entry.name)")
                for file in nested ?? [] {
                    paths.append("\(id.uuidString)/\(entry.name)/\(file.name)")
                }
            }
            if !paths.isEmpty {
                _ = try? await client.storage.from(MapArtifactBucket.name).remove(paths: paths)
            }
        }

        _ = try await client
            .rpc("delete_building", params: ["p_building_id": id.uuidString])
            .execute()

        catalog.removeAll { $0.id == id }
        cachedVersions[id] = nil
        try await loadCatalog()
        DiagnosticsLog.shared.log("Deleted building \(id.uuidString.prefix(8))")
    }

    /// Records that this device now holds `version` of a building's map.
    func markCached(buildingID: UUID, version: Int?) {
        guard let version else { return }
        cachedVersions[buildingID] = version
        cache.saveVersion(version, buildingID: buildingID)
    }

    func signOut() async {
        await stopSubscription()
        try? await client?.auth.signOut()
        signedInEmail = nil
        connection = .offline
    }

    // MARK: - Buildings and graph

    func loadBuildings() async throws {
        guard let client else { throw BackendError.notConfigured }
        buildings = try await client
            .from("buildings")
            .select("id,name,address,active_map_version_id,anchor_lat,anchor_lng,anchor_alt_m,heading_deg,scale,formatted_address,footprint_geojson,footprint_height_m")
            .order("name")
            .execute()
            .value

        // The catalogue RPC computes status/counts but cannot return the
        // anchor columns, and this select is the reverse. Folding the anchor
        // into the catalogue entries means callers read one list, not two that
        // have to be joined by id at the point of use.
        let anchors = Dictionary(uniqueKeysWithValues: buildings.map { ($0.id, $0) })
        catalog = catalog.map { entry in
            guard let a = anchors[entry.id] else { return entry }
            var merged = entry
            merged.anchorLat = a.anchorLat
            merged.anchorLng = a.anchorLng
            merged.anchorAltM = a.anchorAltM
            merged.headingDeg = a.headingDeg
            merged.scale = a.scale
            merged.formattedAddress = a.formattedAddress
            merged.footprintGeoJSON = a.footprintGeoJSON
            merged.footprintHeightM = a.footprintHeightM
            return merged
        }
    }

    /// Downloads the published graph and caches it. On failure, falls back to
    /// the cached copy so the app still works offline.
    func loadGraph(for building: RemoteBuilding) async throws {
        currentBuildingID = building.id
        guard let client else { throw BackendError.notConfigured }
        guard let mapVersion = building.activeMapVersionID else {
            if let cached = cache.loadGraph(buildingID: building.id) {
                graph = cached
                usingCache = true
                return
            }
            throw BackendError.noPublishedMap
        }

        do {
            async let nodes: [RemoteRouteNode] = client
                .from("route_nodes").select("stable_id,floor_id,name,type,position")
                .eq("map_version_id", value: mapVersion.uuidString).execute().value
            async let edges: [RemoteRouteEdge] = client
                .from("route_edges")
                .select("stable_id,from_node_stable_id,to_node_stable_id,distance_meters,bidirectional,contains_stairs,requires_elevator,wheelchair_accessible")
                .eq("map_version_id", value: mapVersion.uuidString).execute().value

            let built = RemoteGraphMapper.graph(
                buildingID: building.id, nodes: try await nodes, edges: try await edges
            )
            graph = built
            usingCache = false
            cache.saveGraph(built, buildingID: building.id)
            if let match = catalog.first(where: { $0.id == building.id }) {
                markCached(buildingID: building.id, version: match.version)
            }
        } catch {
            // Offline: keep going on cached data rather than failing the user.
            if let cached = cache.loadGraph(buildingID: building.id) {
                graph = cached
                usingCache = true
                lastError = "Using cached map — \(error.localizedDescription)"
            } else {
                throw error
            }
        }
    }

    // MARK: - Occupant reports

    /// Submits an occupant report for administrator review.
    ///
    /// Deliberately an insert into `user_reports`, not a live-state write: an
    /// occupant must never be able to close a corridor for the whole building.
    /// The reporting phone has already protected itself through its personal
    /// overlay by the time this runs, so a failure here costs that phone
    /// nothing — it is reported and swallowed rather than thrown into an
    /// evacuation.
    @discardableResult
    func submitReport(
        buildingID: UUID,
        edgeStableID: UUID?,
        nodeStableID: UUID? = nil,
        type: RouteHazardType,
        description: String?
    ) async -> Bool {
        guard let client else { return false }
        struct NewReport: Encodable {
            let building_id: String
            let edge_stable_id: String?
            let node_stable_id: String?
            let report_type: String
            let description: String?
        }
        do {
            try await client.from("user_reports").insert(NewReport(
                building_id: buildingID.uuidString,
                edge_stable_id: edgeStableID?.uuidString,
                node_stable_id: nodeStableID?.uuidString,
                report_type: type.rawValue,
                description: description
            )).execute()
            DiagnosticsLog.shared.log("Report submitted: \(type.rawValue)")
            return true
        } catch {
            DiagnosticsLog.shared.log("Report submission failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - BuildingStateService

    func fetchSnapshot(buildingID: UUID) async throws -> BuildingStateSnapshot {
        guard let client else { throw BackendError.notConfigured }
        let raw: BuildingStateSnapshot = try await client
            .rpc("building_state_snapshot", params: ["p_building_id": buildingID.uuidString])
            .execute()
            .value
        cache.saveSnapshot(raw, buildingID: buildingID)
        return raw
    }

    /// Fetches the authoritative snapshot, then subscribes. Doing it in that
    /// order means no change can slip through the gap between the two.
    func subscribe(buildingID: UUID) async throws {
        await stopSubscription()
        currentBuildingID = buildingID
        connection = .connecting

        var applied = LiveStateOverlay(buildingID: buildingID)
        do {
            applied.replace(with: try await fetchSnapshot(buildingID: buildingID))
            usingCache = false
        } catch {
            // Offline start: use whatever we cached last time.
            if let cached = cache.loadSnapshot(buildingID: buildingID) {
                applied.replace(with: cached)
                usingCache = true
                lastError = "Offline — using the last known building state."
            }
            connection = .error
        }
        overlay = applied
        onStateChanged?(nil)

        guard let client else { throw BackendError.notConfigured }
        let channel = client.realtimeV2.channel("live-\(buildingID.uuidString)")
        let changes = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "live_edge_states",
            filter: "building_id=eq.\(buildingID.uuidString)"
        )
        self.channel = channel

        listenTask = Task { [weak self] in
            await channel.subscribe()
            await MainActor.run { self?.connection = .live }
            for await change in changes {
                guard let self else { return }
                await self.handle(change: change)
            }
        }
    }

    func stopSubscription() async {
        listenTask?.cancel()
        listenTask = nil
        if let channel { await channel.unsubscribe() }
        channel = nil
        if connection == .live { connection = .offline }
    }

    /// Called when the app returns to the foreground or the network recovers:
    /// the server snapshot always wins over accumulated events.
    func refreshSnapshot() async {
        guard let buildingID = currentBuildingID else { return }
        do {
            let snapshot = try await fetchSnapshot(buildingID: buildingID)
            var updated = overlay ?? LiveStateOverlay(buildingID: buildingID)
            updated.replace(with: snapshot)
            overlay = updated
            usingCache = false
            lastError = nil
            connection = .live
            onStateChanged?(nil)
        } catch {
            connection = .error
            lastError = error.localizedDescription
        }
    }

    private func handle(change: AnyAction) async {
        guard var current = overlay else { return }
        let record: [String: AnyJSON]?
        switch change {
        case .insert(let action): record = action.record
        case .update(let action): record = action.record
        case .delete: record = nil
        @unknown default: record = nil
        }
        guard let record, let state = Self.decodeEdgeState(record) else { return }
        guard state.edgeStableID != UUID() else { return }

        let changed = current.apply(edge: state)
        overlay = current
        if changed { onStateChanged?(state) }
        if let buildingID = currentBuildingID {
            cache.saveSnapshot(
                BuildingStateSnapshot(
                    buildingID: buildingID,
                    revision: current.revision,
                    edges: Array(current.edgeStates.values),
                    nodes: Array(current.nodeStates.values)
                ),
                buildingID: buildingID
            )
        }
    }

    /// Realtime payloads arrive as loose JSON, so decode defensively — a shape
    /// we do not recognise must be ignored, not crash a running evacuation.
    static func decodeEdgeState(_ record: [String: AnyJSON]) -> LiveEdgeState? {
        guard
            let idString = record["edge_stable_id"]?.stringValue,
            let id = UUID(uuidString: idString),
            let statusRaw = record["status"]?.stringValue,
            let status = LiveStatus(rawValue: statusRaw)
        else { return nil }

        let revision: Int64
        if let value = record["revision"]?.intValue { revision = Int64(value) }
        else if let d = record["revision"]?.doubleValue { revision = Int64(d) }
        else { return nil }

        var expires: Date?
        if let raw = record["expires_at"]?.stringValue {
            expires = ISO8601DateFormatter.egressParsers.compactMap { $0.date(from: raw) }.first
        }

        return LiveEdgeState(
            edgeStableID: id,
            status: status,
            hazardType: record["hazard_type"]?.stringValue,
            reason: record["reason"]?.stringValue,
            severity: record["severity"]?.intValue ?? 3,
            revision: revision,
            expiresAt: expires
        )
    }
}

extension ISO8601DateFormatter {
    /// Postgres timestamps may or may not carry fractional seconds.
    static let egressParsers: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()
}
