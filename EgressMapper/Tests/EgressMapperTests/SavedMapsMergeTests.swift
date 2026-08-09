import XCTest
@testable import EgressMapper

private let org = UUID()

private func admin() -> UserProfile {
    UserProfile(userID: UUID(), organizationID: org, organizationName: "Org", role: "admin")
}
private func student() -> UserProfile {
    UserProfile(userID: UUID(), organizationID: org, organizationName: "Org", role: "viewer")
}

private func published(_ name: String, id: UUID = UUID(), version: Int = 1) -> CatalogBuilding {
    CatalogBuilding(
        id: id, name: name, address: "1 Test St", description: nil, status: "published",
        activeMapVersionID: UUID(), version: version, publishedAt: nil,
        nodeCount: 7, artifactCount: 3
    )
}

private func draftBuilding(_ name: String, id: UUID = UUID()) -> CatalogBuilding {
    CatalogBuilding(
        id: id, name: name, address: nil, description: nil, status: "draft",
        activeMapVersionID: nil, version: nil, publishedAt: nil, nodeCount: 0, artifactCount: 0
    )
}

private func localZone(_ name: String, remote: UUID? = nil) -> MappingZone {
    MappingZone(
        campus: "Main", building: name, floor: "1", zoneName: name, remoteBuildingID: remote
    )
}

final class SavedMapsMergeTests: XCTestCase {

    // MARK: - Merging identities

    func testAPublishedBuildingAndItsLocalZoneShareOneRow() {
        let building = published("Wade Academic Center")
        let local = localZone("Wade Academic Center", remote: building.id)

        let entries = BuildingCatalogMerger.merge(
            remote: [building], localZones: [local], cachedVersion: { _ in nil }, profile: admin()
        )

        XCTAssertEqual(entries.count, 1, "no duplicate card for a published local zone")
        XCTAssertEqual(entries[0].remote?.id, building.id)
        XCTAssertEqual(entries[0].localZone?.id, local.id)
    }

    func testAnUnrelatedLocalZoneStaysItsOwnRowForAMapper() {
        let building = published("Wade")
        let unrelated = localZone("Science Hall")

        let entries = BuildingCatalogMerger.merge(
            remote: [building], localZones: [localZone("Wade", remote: building.id), unrelated],
            cachedVersion: { _ in nil }, profile: admin()
        )

        XCTAssertEqual(entries.count, 2)
        let draftRow = entries.first { $0.isLocalOnly }
        XCTAssertEqual(draftRow?.availability, .localDraft)
    }

    func testAStudentNeverSeesLocalDrafts() {
        let entries = BuildingCatalogMerger.merge(
            remote: [], localZones: [localZone("Half-mapped Hall")],
            cachedVersion: { _ in nil }, profile: student()
        )
        XCTAssertTrue(entries.isEmpty, "an occupant has no business seeing an unpublished draft")
    }

    // MARK: - Availability

    func testStatusesReflectWhatIsOnTheDevice() {
        let building = published("Wade", version: 3)
        let profile = student()

        let notDownloaded = BuildingCatalogMerger.merge(
            remote: [building], localZones: [], cachedVersion: { _ in nil }, profile: profile
        )
        XCTAssertEqual(notDownloaded[0].availability, .downloadRequired)
        XCTAssertFalse(notDownloaded[0].availability.isUsableOffline)

        let current = BuildingCatalogMerger.merge(
            remote: [building], localZones: [], cachedVersion: { _ in 3 }, profile: profile
        )
        XCTAssertEqual(current[0].availability, .offlineAvailable)
        XCTAssertTrue(current[0].availability.isUsableOffline)

        let stale = BuildingCatalogMerger.merge(
            remote: [building], localZones: [], cachedVersion: { _ in 2 }, profile: profile
        )
        XCTAssertEqual(stale[0].availability, .updateAvailable(cached: 2, latest: 3))
        XCTAssertTrue(
            stale[0].availability.isUsableOffline,
            "an out-of-date package still gets someone out of the building"
        )
    }

    func testTransientStateOverridesTheStoredOne() {
        let building = published("Wade")
        let downloading = BuildingCatalogMerger.merge(
            remote: [building], localZones: [], cachedVersion: { _ in nil },
            profile: student(), transient: [building.id: .downloading]
        )
        XCTAssertEqual(downloading[0].availability, .downloading)

        let failed = BuildingCatalogMerger.merge(
            remote: [building], localZones: [], cachedVersion: { _ in nil },
            profile: student(), transient: [building.id: .downloadFailed("No network")]
        )
        XCTAssertEqual(failed[0].availability, .downloadFailed("No network"))
        XCTAssertTrue(failed[0].availability.label.contains("No network"))
    }

    func testAMapperSeesTheirOwnPublishedBuildingAsPublishedByYou() {
        let building = published("Wade")
        let entries = BuildingCatalogMerger.merge(
            remote: [building], localZones: [localZone("Wade", remote: building.id)],
            cachedVersion: { _ in 1 }, profile: admin()
        )
        XCTAssertEqual(entries[0].availability, .publishedByYou)
    }

    func testEveryStatusHasAUserFacingLabel() {
        let statuses: [BuildingAvailability] = [
            .localDraft, .publishedByYou, .downloadRequired, .downloading,
            .offlineAvailable, .updateAvailable(cached: 1, latest: 2), .downloadFailed("timeout"),
        ]
        for status in statuses {
            XCTAssertFalse(status.label.isEmpty)
        }
        XCTAssertEqual(BuildingAvailability.updateAvailable(cached: 1, latest: 2).label,
                       "Update Available (v1 → v2)")
    }

    // MARK: - Role-based actions

    func testAStudentNeverGetsAWriteAction() {
        let building = published("Wade")
        let profiles = [student()]
        let caches: [Int?] = [nil, 1, 0]

        for profile in profiles {
            for cache in caches {
                let entries = BuildingCatalogMerger.merge(
                    remote: [building], localZones: [localZone("Wade", remote: building.id)],
                    cachedVersion: { _ in cache }, profile: profile
                )
                let actions = entries[0].actions(for: profile)
                XCTAssertTrue(
                    actions.allSatisfy { !$0.requiresManageRole },
                    "occupant was offered \(actions.filter(\.requiresManageRole))"
                )
                XCTAssertFalse(actions.contains(.publishUpdate))
                XCTAssertFalse(actions.contains(.edit))
                XCTAssertFalse(actions.contains(.attachToBuilding))
            }
        }
    }

    func testAStudentCanDownloadUpdateAndEvacuate() {
        let building = published("Wade", version: 2)
        let profile = student()

        let fresh = BuildingCatalogMerger.merge(
            remote: [building], localZones: [], cachedVersion: { _ in nil }, profile: profile
        )[0].actions(for: profile)
        XCTAssertTrue(fresh.contains(.download))
        XCTAssertFalse(fresh.contains(.useInEmergency), "nothing is cached yet")

        let cached = BuildingCatalogMerger.merge(
            remote: [building], localZones: [], cachedVersion: { _ in 2 }, profile: profile
        )[0].actions(for: profile)
        XCTAssertTrue(cached.contains(.useInEmergency))
        XCTAssertTrue(cached.contains(.removeDownload))

        let stale = BuildingCatalogMerger.merge(
            remote: [building], localZones: [], cachedVersion: { _ in 1 }, profile: profile
        )[0].actions(for: profile)
        XCTAssertTrue(stale.contains(.update))
        XCTAssertTrue(stale.contains(.useInEmergency))
    }

    func testAMapperGetsDraftAndPublishActions() {
        let profile = admin()
        let localOnly = BuildingCatalogMerger.merge(
            remote: [], localZones: [localZone("Science Hall")],
            cachedVersion: { _ in nil }, profile: profile
        )[0].actions(for: profile)
        XCTAssertTrue(localOnly.contains(.openDraft))
        XCTAssertTrue(localOnly.contains(.attachToBuilding))
        XCTAssertTrue(localOnly.contains(.testRoute))
        XCTAssertFalse(localOnly.contains(.publishUpdate), "it is not attached to a building yet")

        let building = published("Wade")
        let attached = BuildingCatalogMerger.merge(
            remote: [building], localZones: [localZone("Wade", remote: building.id)],
            cachedVersion: { _ in 1 }, profile: profile
        )[0].actions(for: profile)
        XCTAssertTrue(attached.contains(.publishUpdate))
        XCTAssertTrue(attached.contains(.viewPublicationState))
    }

    func testADraftBuildingOffersNoDownloadToAnyone() {
        let profile = admin()
        let entries = BuildingCatalogMerger.merge(
            remote: [draftBuilding("Unfinished Hall")], localZones: [],
            cachedVersion: { _ in nil }, profile: profile
        )
        let actions = entries[0].actions(for: profile)
        XCTAssertFalse(actions.contains(.download), "there is no published version to download")
        XCTAssertFalse(actions.contains(.useInEmergency))
    }

    func testActionOrderIsStable() {
        let building = published("Wade")
        let profile = admin()
        let entry = BuildingCatalogMerger.merge(
            remote: [building], localZones: [localZone("Wade", remote: building.id)],
            cachedVersion: { _ in 1 }, profile: profile
        )[0]
        XCTAssertEqual(entry.actions(for: profile), entry.actions(for: profile))
        XCTAssertEqual(Set(entry.actions(for: profile)).count, entry.actions(for: profile).count)
    }

    func testEntriesAreSortedByName() {
        let entries = BuildingCatalogMerger.merge(
            remote: [published("Wade"), published("Anderson"), published("Science")],
            localZones: [], cachedVersion: { _ in nil }, profile: student()
        )
        XCTAssertEqual(entries.map(\.name), ["Anderson", "Science", "Wade"])
    }
}
