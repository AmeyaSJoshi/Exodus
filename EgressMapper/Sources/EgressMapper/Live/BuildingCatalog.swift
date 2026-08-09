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

    enum CodingKeys: String, CodingKey {
        case id, name, address, description, status
        case activeMapVersionID = "active_map_version_id"
        case version
        case publishedAt = "published_at"
        case nodeCount = "node_count"
        case artifactCount = "artifact_count"
    }

    var isPublished: Bool { status == "published" }
}

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

        // Same rule the merge uses: a device with no resolved account is
        // treated as its own mapper, so a map just recorded on this phone can
        // be opened before anyone signs in. Once an account resolves to an
        // occupant, the write actions disappear — and RLS refuses them anyway.
        let mayManage = profile.canManageBuildings || !profile.hasOrganization

        if mayManage {
            if localZone != nil {
                available += [.openDraft, .edit, .testRoute]
                // Attaching to a building is a server write, so it needs a
                // real administrator account, not merely a signed-out device.
                if profile.canManageBuildings {
                    available.append(remote == nil ? .attachToBuilding : .publishUpdate)
                }
            }
            if remote != nil, profile.canManageBuildings {
                available.append(.viewPublicationState)
            }
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
    // Everyone
    case viewBuilding
    case download
    case update
    case useInEmergency
    case removeDownload

    /// True for the actions that write to the backend. Only a mapper or
    /// administrator ever sees these, and RLS rejects them for anyone else.
    var requiresManageRole: Bool {
        switch self {
        case .openDraft, .edit, .attachToBuilding, .testRoute, .publishUpdate, .viewPublicationState:
            return true
        case .viewBuilding, .download, .update, .useInEmergency, .removeDownload:
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

        // Zones that were never published stay visible to their mapper, and to
        // a signed-out device: these are recordings made on this phone, and
        // losing sight of them until you sign in would be absurd. Once an
        // account resolves to an occupant, they are hidden.
        if profile.canManageBuildings || !profile.hasOrganization {
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
