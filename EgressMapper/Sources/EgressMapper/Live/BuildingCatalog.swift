import Foundation

/// The authenticated user's role and organization, read from their profile.
/// The client never supplies an organization id — the server resolves it.
struct UserProfile: Codable, Hashable {
    var userID: UUID?
    var organizationID: UUID?
    var organizationName: String?
    var role: String?
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case organizationID = "organization_id"
        case organizationName = "organization_name"
        case role, displayName = "display_name"
    }

    /// Mappers and administrators share one role today.
    var canManageBuildings: Bool { role == "admin" }
    var hasOrganization: Bool { organizationID != nil }

    static let empty = UserProfile()
}

/// A building as the organization sees it, before any local state is merged.
struct CatalogBuilding: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var address: String?
    var description: String?
    var status: String
    var activeMapVersionID: UUID?
    var version: Int?
    /// Kept as the raw ISO string: PostgREST sends a timestamp, and the default
    /// JSONDecoder date strategy would reject it and fail the whole catalogue.
    var publishedAt: String?
    var nodeCount: Int
    var artifactCount: Int

    // Georeference anchor and cached OSM footprint (migrations 20260806000900
    // and ...1000). Only the `buildings` table select returns these; the
    // catalogue RPC does not, which is why they are optional.
    var anchorLat: Double?
    var anchorLng: Double?
    var anchorAltM: Double?
    var headingDeg: Double?
    var scale: Double?
    var formattedAddress: String?
    var footprintGeoJSON: FootprintPolygon?
    var footprintHeightM: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, address, description, status
        case activeMapVersionID = "active_map_version_id"
        case version
        case publishedAt = "published_at"
        case nodeCount = "node_count"
        case artifactCount = "artifact_count"
        case anchorLat = "anchor_lat"
        case anchorLng = "anchor_lng"
        case anchorAltM = "anchor_alt_m"
        case headingDeg = "heading_deg"
        case scale
        case formattedAddress = "formatted_address"
        case footprintGeoJSON = "footprint_geojson"
        case footprintHeightM = "footprint_height_m"
    }

    init(
        id: UUID,
        name: String,
        address: String? = nil,
        description: String? = nil,
        status: String = "draft",
        activeMapVersionID: UUID? = nil,
        version: Int? = nil,
        publishedAt: String? = nil,
        nodeCount: Int = 0,
        artifactCount: Int = 0,
        anchorLat: Double? = nil,
        anchorLng: Double? = nil,
        anchorAltM: Double? = nil,
        headingDeg: Double? = nil,
        scale: Double? = nil,
        formattedAddress: String? = nil,
        footprintGeoJSON: FootprintPolygon? = nil,
        footprintHeightM: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.description = description
        self.status = status
        self.activeMapVersionID = activeMapVersionID
        self.version = version
        self.publishedAt = publishedAt
        self.nodeCount = nodeCount
        self.artifactCount = artifactCount
        self.anchorLat = anchorLat
        self.anchorLng = anchorLng
        self.anchorAltM = anchorAltM
        self.headingDeg = headingDeg
        self.scale = scale
        self.formattedAddress = formattedAddress
        self.footprintGeoJSON = footprintGeoJSON
        self.footprintHeightM = footprintHeightM
    }

    /// Two queries feed this one model: the catalogue RPC, which computes
    /// `status`/`node_count`/`artifact_count`, and a plain `buildings` select,
    /// which carries the anchor but none of the computed columns. Defaulting
    /// the missing side here is what lets both decode into a single type.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "draft"
        activeMapVersionID = try c.decodeIfPresent(UUID.self, forKey: .activeMapVersionID)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        nodeCount = try c.decodeIfPresent(Int.self, forKey: .nodeCount) ?? 0
        artifactCount = try c.decodeIfPresent(Int.self, forKey: .artifactCount) ?? 0
        anchorLat = try c.decodeIfPresent(Double.self, forKey: .anchorLat)
        anchorLng = try c.decodeIfPresent(Double.self, forKey: .anchorLng)
        anchorAltM = try c.decodeIfPresent(Double.self, forKey: .anchorAltM)
        headingDeg = try c.decodeIfPresent(Double.self, forKey: .headingDeg)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale)
        formattedAddress = try c.decodeIfPresent(String.self, forKey: .formattedAddress)
        footprintGeoJSON = try c.decodeIfPresent(FootprintPolygon.self, forKey: .footprintGeoJSON)
        footprintHeightM = try c.decodeIfPresent(Double.self, forKey: .footprintHeightM)
    }

    var isPublished: Bool { status == "published" }

    /// The anchor is only usable when both coordinates are present.
    var anchor: BuildingAnchor? {
        guard let anchorLat, let anchorLng else { return nil }
        return BuildingAnchor(
            latitude: anchorLat,
            longitude: anchorLng,
            altitudeM: anchorAltM ?? 0,
            headingDeg: headingDeg ?? 0,
            scale: (scale ?? 1) > 0 ? (scale ?? 1) : 1
        )
    }
}

/// The `buildings` table and the catalogue RPC are two views of one row, so
/// they decode into one model. The old name is kept as an alias because both
/// spellings are load-bearing at a dozen call sites.
typealias RemoteBuilding = CatalogBuilding

/// How a building stands on *this* device.
enum BuildingAvailability: Equatable, Hashable {
    case localDraft
    case publishedByYou
    case downloadRequired
    case downloading
    case offlineAvailable
    case updateAvailable(cached: Int, latest: Int)
    case downloadFailed(String)

    var label: String {
        switch self {
        case .localDraft: return "Local Draft"
        case .publishedByYou: return "Published by You"
        case .downloadRequired: return "Download Required"
        case .downloading: return "Downloading…"
        case .offlineAvailable: return "Offline Available"
        case .updateAvailable(let cached, let latest): return "Update Available (v\(cached) → v\(latest))"
        case .downloadFailed(let reason): return "Download Failed — \(reason)"
        }
    }

    /// Only these can start an evacuation without a network round trip.
    var isUsableOffline: Bool {
        switch self {
        case .offlineAvailable, .updateAvailable, .publishedByYou: return true
        default: return false
        }
    }
}

/// One row in the unified Saved Maps list: a remote building, a local zone, or
/// both once a zone has been published.
struct BuildingEntry: Identifiable, Hashable {
    var id: UUID
    var name: String
    var subtitle: String
    var remote: CatalogBuilding?
    var localZone: MappingZone?
    var availability: BuildingAvailability

    var isRemote: Bool { remote != nil }
    var isLocalOnly: Bool { remote == nil && localZone != nil }

    /// What this user may do with this row. Mirrors what RLS enforces on the
    /// server: an occupant seeing an edit control would be a UI bug, but the
    /// server would reject the write regardless.
    func actions(for profile: UserProfile) -> [BuildingAction] {
        var available: [BuildingAction] = []

        // Anything that only touches this device is available to whoever is
        // holding it — recording, opening, testing and deleting your own map
        // are not privileges. Only the actions that write to the backend are
        // gated, and RLS refuses those independently.
        if localZone != nil {
            available += [.openDraft, .edit, .testRoute, .deleteLocalMap]
            if profile.canManageBuildings {
                available.append(remote == nil ? .attachToBuilding : .publishUpdate)
            }
        }
        if remote != nil, profile.canManageBuildings {
            available += [.viewPublicationState, .deleteBuilding]
        }

        if let remote, remote.isPublished {
            switch availability {
            case .downloadRequired, .downloadFailed:
                available.append(.download)
            case .updateAvailable:
                available += [.update, .useInEmergency]
            case .offlineAvailable:
                available += [.useInEmergency, .removeDownload]
            case .publishedByYou:
                available.append(.useInEmergency)
                // A mapper's own device may still not hold the *published*
                // package — only the local draft it was published from.
                available.append(.download)
            case .downloading, .localDraft:
                break
            }
            available.append(.viewBuilding)
        } else if localZone != nil {
            available.append(.useInEmergency)
        }

        // Stable, de-duplicated order so the row does not reshuffle.
        var seen: Set<BuildingAction> = []
        return BuildingAction.displayOrder.filter { available.contains($0) && seen.insert($0).inserted }
    }
}

/// Every action a Saved Maps row can offer. Which ones appear is decided by
/// role and availability, never by the view.
enum BuildingAction: String, Hashable, CaseIterable {
    // Administrator / mapper
    case openDraft
    case edit
    case attachToBuilding
    case testRoute
    case publishUpdate
    case viewPublicationState
    /// Deletes the recording held on this device. Anything published stays.
    case deleteLocalMap
    /// Deletes the building and every version of its map for the whole
    /// organization. Administrators only.
    case deleteBuilding
    // Everyone
    case viewBuilding
    case download
    case update
    case useInEmergency
    case removeDownload

    /// True for the actions that write to the backend. Only a mapper or
    /// administrator ever sees these, and RLS rejects them for anyone else.
    ///
    /// Opening, editing, testing and deleting a map held on this device are
    /// deliberately *not* in this list. They change nothing anyone else can
    /// see, so gating them on a role only ever hid someone's own work from
    /// them.
    var requiresManageRole: Bool {
        switch self {
        case .attachToBuilding, .publishUpdate, .viewPublicationState, .deleteBuilding:
            return true
        case .openDraft, .edit, .testRoute, .deleteLocalMap,
             .viewBuilding, .download, .update, .useInEmergency, .removeDownload:
            return false
        }
    }

    var label: String {
        switch self {
        case .openDraft: return "Open Draft"
        case .edit: return "Edit"
        case .attachToBuilding: return "Attach to Building"
        case .testRoute: return "Test Route"
        case .publishUpdate: return "Publish Update"
        case .viewPublicationState: return "Publication State"
        case .deleteLocalMap: return "Delete From Device"
        case .deleteBuilding: return "Delete Building"
        case .viewBuilding: return "View Building"
        case .download: return "Download"
        case .update: return "Update"
        case .useInEmergency: return "Use in Emergency"
        case .removeDownload: return "Remove Download"
        }
    }

    var symbolName: String {
        switch self {
        case .openDraft: return "folder"
        case .edit: return "pencil"
        case .attachToBuilding: return "link"
        case .testRoute: return "figure.walk"
        case .publishUpdate: return "arrow.up.circle"
        case .viewPublicationState: return "info.circle"
        case .deleteLocalMap: return "trash"
        case .deleteBuilding: return "trash.fill"
        case .viewBuilding: return "building.2"
        case .download: return "arrow.down.circle"
        case .update: return "arrow.triangle.2.circlepath"
        case .useInEmergency: return "figure.run"
        case .removeDownload: return "trash"
        }
    }

    static let displayOrder: [BuildingAction] = [
        .useInEmergency, .download, .update, .openDraft, .edit, .testRoute,
        .attachToBuilding, .publishUpdate, .viewBuilding, .viewPublicationState, .removeDownload,
        .deleteLocalMap, .deleteBuilding,
    ]
}

/// Merges the organization catalogue with locally saved zones and the download
/// cache. Pure so the merge rules are unit tested without a network.
enum BuildingCatalogMerger {

    /// A local zone and a remote building are the same thing when the zone
    /// records the remote id it was published to.
    /// - Parameter transient: in-flight states (downloading, failed) that no
    ///   amount of stored data can imply. They win over the computed value.
    static func merge(
        remote: [CatalogBuilding],
        localZones: [MappingZone],
        cachedVersion: (UUID) -> Int?,
        profile: UserProfile,
        transient: [UUID: BuildingAvailability] = [:]
    ) -> [BuildingEntry] {
        var entries: [BuildingEntry] = []
        var claimedZoneIDs: Set<UUID> = []

        for building in remote {
            // One card per published building. A local zone that was published
            // to it is folded in rather than listed a second time.
            let zone = localZones.first { $0.remoteBuildingID == building.id }
            if let zone { claimedZoneIDs.insert(zone.id) }

            entries.append(
                BuildingEntry(
                    id: building.id,
                    name: building.name,
                    subtitle: subtitle(for: building),
                    remote: building,
                    localZone: zone,
                    availability: transient[building.id] ?? availability(
                        for: building,
                        hasLocalZone: zone != nil,
                        cached: cachedVersion(building.id),
                        profile: profile
                    )
                )
            )
        }

        // A zone that was never published is a recording made on *this phone*,
        // by whoever is holding it. It is not organization data, so role has no
        // business filtering it: hiding an occupant's own map made it look like
        // the save had failed. Anyone may record and open their own maps; only
        // an administrator may push one to the backend, which is enforced in
        // `actions(for:)` and by RLS.
        for zone in localZones where !claimedZoneIDs.contains(zone.id) {
            entries.append(
                BuildingEntry(
                    id: zone.id,
                    name: zone.displayTitle,
                    subtitle: zone.displaySubtitle,
                    remote: nil,
                    localZone: zone,
                    availability: .localDraft
                )
            )
        }

        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func subtitle(for building: CatalogBuilding) -> String {
        var parts: [String] = []
        if let address = building.address, !address.isEmpty { parts.append(address) }
        if let version = building.version { parts.append("v\(version)") }
        parts.append("\(building.nodeCount) nodes")
        return parts.joined(separator: " · ")
    }

    static func availability(
        for building: CatalogBuilding,
        hasLocalZone: Bool,
        cached: Int?,
        profile: UserProfile
    ) -> BuildingAvailability {
        guard let latest = building.version else { return .downloadRequired }
        guard let cached else {
            return hasLocalZone && profile.canManageBuildings ? .publishedByYou : .downloadRequired
        }
        if cached < latest { return .updateAvailable(cached: cached, latest: latest) }
        return hasLocalZone && profile.canManageBuildings ? .publishedByYou : .offlineAvailable
    }
}
