import XCTest
@testable import EgressMapper

private let orgID = UUID()

private func admin() -> UserProfile {
    UserProfile(userID: UUID(), organizationID: orgID, organizationName: "Org", role: "admin")
}
private func student() -> UserProfile {
    UserProfile(userID: UUID(), organizationID: orgID, organizationName: "Org", role: "viewer")
}

private func building(_ name: String, id: UUID = UUID(), version: Int? = 1, status: String = "published") -> CatalogBuilding {
    CatalogBuilding(
        id: id, name: name, address: "1 Test St", description: nil, status: status,
        activeMapVersionID: version == nil ? nil : UUID(), version: version,
        publishedAt: nil, nodeCount: 7, artifactCount: 0
    )
}

private func makeZone(_ name: String, remote: UUID? = nil) -> MappingZone {
    MappingZone(campus: "C", building: "B", floor: "F", zoneName: name, remoteBuildingID: remote)
}

final class BuildingCatalogMergeTests: XCTestCase {

    func testStudentSeesPublishedOrganizationBuildings() {
        let entries = BuildingCatalogMerger.merge(
            remote: [building("Wade")], localZones: [], cachedVersion: { _ in nil }, profile: student()
        )
        XCTAssertEqual(entries.map(\.name), ["Wade"])
        XCTAssertEqual(entries[0].availability, .downloadRequired)
    }

    func testStudentDoesNotSeeSomebodyElsesLocalDrafts() {
        let entries = BuildingCatalogMerger.merge(
            remote: [], localZones: [makeZone("Unpublished")], cachedVersion: { _ in nil }, profile: student()
        )
        XCTAssertTrue(entries.isEmpty, "A student must not see local drafts")
    }

    func testAdminSeesLocalDraftsAsWell() {
        let entries = BuildingCatalogMerger.merge(
            remote: [], localZones: [makeZone("Unpublished")], cachedVersion: { _ in nil }, profile: admin()
        )
        XCTAssertEqual(entries.map(\.availability), [.localDraft])
    }

    /// The same building must not appear twice once its zone is published.
    func testPublishedZoneIsMergedWithItsRemoteBuilding() {
        let id = UUID()
        let entries = BuildingCatalogMerger.merge(
            remote: [building("Wade", id: id)],
            localZones: [makeZone("Wade East Hallway", remote: id)],
            cachedVersion: { _ in nil },
            profile: admin()
        )
        XCTAssertEqual(entries.count, 1, "A published zone must not duplicate its building")
        XCTAssertNotNil(entries[0].remote)
        XCTAssertNotNil(entries[0].localZone)
        XCTAssertEqual(entries[0].availability, .publishedByYou)
    }

    func testUnrelatedLocalZoneIsNotAbsorbedIntoABuilding() {
        let entries = BuildingCatalogMerger.merge(
            remote: [building("Wade")],
            localZones: [makeZone("Somewhere else")],
            cachedVersion: { _ in nil },
            profile: admin()
        )
        XCTAssertEqual(entries.count, 2)
    }

    func testCachedAtLatestVersionIsOfflineAvailable() {
        let id = UUID()
        let entries = BuildingCatalogMerger.merge(
            remote: [building("Wade", id: id, version: 3)],
            localZones: [], cachedVersion: { _ in 3 }, profile: student()
        )
        XCTAssertEqual(entries[0].availability, .offlineAvailable)
        XCTAssertTrue(entries[0].availability.isUsableOffline)
    }

    func testOlderCacheReportsUpdateAvailable() {
        let id = UUID()
        let entries = BuildingCatalogMerger.merge(
            remote: [building("Wade", id: id, version: 4)],
            localZones: [], cachedVersion: { _ in 2 }, profile: student()
        )
        XCTAssertEqual(entries[0].availability, .updateAvailable(cached: 2, latest: 4))
        XCTAssertTrue(entries[0].availability.label.contains("v2 → v4"))
        XCTAssertTrue(entries[0].availability.isUsableOffline, "A stale cache is still usable offline")
    }

    func testBuildingWithNoPublishedVersionNeedsDownload() {
        let entries = BuildingCatalogMerger.merge(
            remote: [building("Draft Hall", version: nil, status: "draft")],
            localZones: [], cachedVersion: { _ in nil }, profile: admin()
        )
        XCTAssertEqual(entries[0].availability, .downloadRequired)
    }

    func testEntriesAreSortedByName() {
        let entries = BuildingCatalogMerger.merge(
            remote: [building("Zulu"), building("Alpha")],
            localZones: [], cachedVersion: { _ in nil }, profile: student()
        )
        XCTAssertEqual(entries.map(\.name), ["Alpha", "Zulu"])
    }

    func testSubtitleShowsVersionAndNodeCount() {
        let text = BuildingCatalogMerger.subtitle(for: building("Wade", version: 2))
        XCTAssertTrue(text.contains("v2"))
        XCTAssertTrue(text.contains("7 nodes"))
    }
}

final class UserProfileTests: XCTestCase {

    func testRoleGatesBuildingManagement() {
        XCTAssertTrue(admin().canManageBuildings)
        XCTAssertFalse(student().canManageBuildings)
        XCTAssertFalse(UserProfile.empty.canManageBuildings)
    }

    func testMissingOrganizationIsDetectable() {
        XCTAssertFalse(UserProfile.empty.hasOrganization)
        XCTAssertTrue(student().hasOrganization)
    }

    func testDecodesServerProfilePayload() throws {
        let json = """
        {"user_id":"\(UUID().uuidString)","organization_id":"\(orgID.uuidString)",
         "organization_name":"Bellarmine","role":"admin","display_name":"Admin"}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(UserProfile.self, from: json)
        XCTAssertEqual(profile.organizationID, orgID)
        XCTAssertTrue(profile.canManageBuildings)
    }

    func testEmptyProfilePayloadDecodesWithoutThrowing() throws {
        let profile = try JSONDecoder().decode(UserProfile.self, from: Data("{}".utf8))
        XCTAssertFalse(profile.hasOrganization)
        XCTAssertFalse(profile.canManageBuildings)
    }
}

final class CatalogBuildingDecodingTests: XCTestCase {

    func testDecodesOrganizationBuildingsRow() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","name":"Wade","address":null,"description":null,
         "status":"published","active_map_version_id":"\(UUID().uuidString)",
         "version":3,"published_at":null,"node_count":7,"artifact_count":2}
        """.data(using: .utf8)!
        let b = try JSONDecoder().decode(CatalogBuilding.self, from: json)
        XCTAssertEqual(b.id, id)
        XCTAssertEqual(b.version, 3)
        XCTAssertEqual(b.nodeCount, 7)
        XCTAssertTrue(b.isPublished)
    }
}

/// Existing saved zones must keep decoding after `remoteBuildingID` was added.
final class MappingZoneCompatibilityTests: XCTestCase {

    func testZoneWithoutRemoteBuildingIDStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","campus":"C","building":"B","floor":"2",
         "zoneName":"East Hallway","createdAt":"2026-08-06T18:00:00Z",
         "updatedAt":"2026-08-06T18:00:00Z","waypointCount":7,"pathLength":118,
         "hasWorldMap":false,"hasFloorPlan":false,"hasReferenceImage":false}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let zone = try decoder.decode(MappingZone.self, from: json)
        XCTAssertNil(zone.remoteBuildingID)
        XCTAssertEqual(zone.waypointCount, 7)
    }
}

final class MapVersionCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VersionCache-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testVersionRoundTripAcrossInstances() {
        let cache = LiveStateCache(root: root)
        let id = UUID()
        cache.saveVersion(4, buildingID: id)
        XCTAssertEqual(LiveStateCache(root: root).loadVersions()[id], 4)
    }

    func testMissingVersionFileIsEmpty() {
        XCTAssertTrue(LiveStateCache(root: root).loadVersions().isEmpty)
    }

    func testUpdatingOneVersionKeepsOthers() {
        let cache = LiveStateCache(root: root)
        let a = UUID(), b = UUID()
        cache.saveVersion(1, buildingID: a)
        cache.saveVersion(2, buildingID: b)
        cache.saveVersion(5, buildingID: a)
        let all = cache.loadVersions()
        XCTAssertEqual(all[a], 5)
        XCTAssertEqual(all[b], 2)
    }
}
