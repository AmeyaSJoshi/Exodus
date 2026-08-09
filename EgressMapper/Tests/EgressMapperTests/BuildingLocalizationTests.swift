import XCTest
import simd
@testable import EgressMapper

private func at(_ x: Float, _ z: Float) -> CodableTransform {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(x, 0, z, 1)
    return CodableTransform(m)
}

/// Two mapped zones in one building, plus a second building that must never be
/// searched.
private struct Fixture {
    let manifest: MapPackageManifest
    let graph: BuildingGraph
    let zoneID: UUID
    let room214: UUID
    let exitID: UUID

    init(withWorldMap: Bool = true, aliases: [String] = ["Rm. 214"]) throws {
        let zone = MappingZone(
            campus: "Main", building: "Wade", floor: "2", zoneName: "East Wing"
        )
        let room = RouteNode(name: "Room 214", type: .room, position: at(0, 0), zoneID: zone.id)
        let hall = RouteNode(name: "East Hallway", type: .hallwayPoint, position: at(6, 0), zoneID: zone.id)
        let exit = RouteNode(name: "East Exit", type: .exit, position: at(12, 0), zoneID: zone.id)
        let sourceGraph = BuildingGraph(
            zoneID: zone.id, nodes: [room, hall, exit],
            edges: [
                RouteEdge(fromNodeID: room.id, toNodeID: hall.id, distanceMeters: 6),
                RouteEdge(fromNodeID: hall.id, toNodeID: exit.id, distanceMeters: 6),
            ]
        )

        var pending: [PendingArtifact] = []
        if withWorldMap {
            pending.append(PendingArtifact(
                kind: .worldmap, zoneID: zone.id, fileName: "worldmap.arexperience",
                data: Data("world".utf8)
            ))
        }
        pending.append(PendingArtifact(
            kind: .referenceImage, zoneID: zone.id, fileName: "ref-north.jpg",
            viewpoint: "toward the stairwell", data: Data("n".utf8)
        ))
        pending.append(PendingArtifact(
            kind: .referenceImage, zoneID: zone.id, fileName: "ref-south.jpg",
            viewpoint: "toward the lobby", data: Data("s".utf8)
        ))

        manifest = try MapPackageBuilder.build(
            zone: zone, graph: sourceGraph, buildingID: UUID(),
            buildingName: "Wade Academic Center", mapVersionID: UUID(), version: 1,
            artifacts: pending, aliases: [room.id: aliases]
        )
        graph = MapPackageBuilder.graph(from: manifest)
        zoneID = zone.id
        room214 = room.id
        exitID = exit.id
    }
}

final class BuildingLocalizationTests: XCTestCase {

    // MARK: - Candidate zones come only from the selected building

    func testOnlyZonesWithAWorldMapAreRelocalizationCandidates() throws {
        let withMap = try Fixture()
        XCTAssertEqual(BuildingLocalizationService.relocalizableZones(in: withMap.manifest).count, 1)

        let withoutMap = try Fixture(withWorldMap: false)
        XCTAssertTrue(
            BuildingLocalizationService.relocalizableZones(in: withoutMap.manifest).isEmpty,
            "a package with no ARWorldMap cannot offer camera relocalization"
        )
    }

    func testAPoseFromAnotherBuildingIsNeverAccepted() throws {
        let wade = try Fixture()
        let other = try Fixture()

        let result = BuildingLocalizationService.locate(
            worldPosition: SIMD3<Float>(0, 0, 0),
            relocalizedZoneID: other.zoneID,
            manifest: wade.manifest,
            graph: wade.graph
        )
        XCTAssertNil(result, "the selected building's package must be the only search space")
    }

    // MARK: - Tracking alone is not localization

    func testNormalTrackingWithoutARelocalizedZoneYieldsNothing() throws {
        let f = try Fixture()
        let result = BuildingLocalizationService.locate(
            worldPosition: SIMD3<Float>(0, 0, 0),
            relocalizedZoneID: nil,
            manifest: f.manifest,
            graph: f.graph
        )
        XCTAssertNil(result, "AR tracking being normal says nothing about where the user is")
    }

    func testRelocalizedPoseNearAMappedRoomIsAccepted() throws {
        let f = try Fixture()
        let result = BuildingLocalizationService.locate(
            worldPosition: SIMD3<Float>(0.4, 1.4, 0.2),
            relocalizedZoneID: f.zoneID,
            manifest: f.manifest,
            graph: f.graph
        )

        let located = try XCTUnwrap(result)
        XCTAssertEqual(located.method, .worldMapRelocalization)
        XCTAssertEqual(located.estimate.nearestNodeName, "Room 214")
        XCTAssertEqual(located.confidence, .high)
        XCTAssertTrue(located.canStartAutomatically)
        XCTAssertEqual(located.routePosition.nodeID, f.room214)
    }

    func testAPoseFarFromEverythingMappedIsRejected() throws {
        let f = try Fixture()
        let result = BuildingLocalizationService.locate(
            worldPosition: SIMD3<Float>(500, 0, 500),
            relocalizedZoneID: f.zoneID,
            manifest: f.manifest,
            graph: f.graph
        )
        XCTAssertNil(result, "relocalizing is not enough — the pose must land on the mapped route")
    }

    // MARK: - Multiple viewpoints and instructions

    func testAZoneOffersEveryStoredViewpoint() throws {
        let f = try Fixture()
        let zone = f.manifest.zones[0]
        let views = BuildingLocalizationService.referenceArtifacts(for: zone, in: f.manifest)

        XCTAssertEqual(views.count, 2)
        XCTAssertEqual(
            Set(views.compactMap(\.viewpoint)),
            ["toward the stairwell", "toward the lobby"],
            "one exact view was the old failure mode; several directions is the fix"
        )
    }

    func testScanInstructionsNameTheAvailableDirections() throws {
        let f = try Fixture()
        let text = BuildingLocalizationService.scanInstructions(for: f.manifest.zones[0], in: f.manifest)
        XCTAssertTrue(text.contains("toward the stairwell"))
        XCTAssertTrue(text.contains("toward the lobby"))
    }

    func testScanInstructionsStillHelpWhenNoViewpointsWereRecorded() throws {
        let zone = MappingZone(campus: "M", building: "B", floor: "1", zoneName: "Z")
        let node = RouteNode(name: "Room 1", type: .room, position: at(0, 0), zoneID: zone.id)
        let manifest = try MapPackageBuilder.build(
            zone: zone, graph: BuildingGraph(zoneID: zone.id, nodes: [node], edges: []),
            buildingID: UUID(), buildingName: "B", mapVersionID: UUID(), version: 1, artifacts: []
        )
        let text = BuildingLocalizationService.scanInstructions(for: manifest.zones[0], in: manifest)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.lowercased().contains("camera"))
    }

    // MARK: - OCR against this building's aliases

    func testAScannedRoomSignResolvesThroughTheBuildingsAliases() throws {
        let f = try Fixture()
        let result = BuildingLocalizationService.locate(
            recognizedText: ["EXIT", "Rm. 214"], manifest: f.manifest, graph: f.graph
        )

        let located = try XCTUnwrap(result)
        XCTAssertEqual(located.method, .signRecognition)
        XCTAssertEqual(located.routePosition.nodeID, f.room214)
        XCTAssertEqual(located.matchedText, "Rm. 214")
    }

    func testABareRoomNumberOnASignStillResolves() throws {
        let f = try Fixture()
        let result = BuildingLocalizationService.locate(
            recognizedText: ["214"], manifest: f.manifest, graph: f.graph
        )
        XCTAssertEqual(try XCTUnwrap(result).routePosition.nodeID, f.room214)
    }

    func testAnUnknownSignIsNotGuessedAt() throws {
        let f = try Fixture()
        let result = BuildingLocalizationService.locate(
            recognizedText: ["Room 244", "Fire Extinguisher"], manifest: f.manifest, graph: f.graph
        )
        XCTAssertNil(result, "a near-miss room number would send someone the wrong way")
    }

    func testASignFromAnotherBuildingDoesNotResolve() throws {
        let wade = try Fixture(aliases: ["Rm. 214"])
        let other = try Fixture(aliases: ["Rm. 900"])

        let result = BuildingLocalizationService.locate(
            recognizedText: ["Rm. 900"], manifest: wade.manifest, graph: wade.graph
        )
        XCTAssertNil(result)
        XCTAssertNotNil(
            BuildingLocalizationService.locate(
                recognizedText: ["Rm. 900"], manifest: other.manifest, graph: other.graph
            ),
            "the same sign resolves in the building it belongs to"
        )
    }

    // MARK: - Manual fallback

    func testManualSelectionAlwaysWorks() throws {
        let f = try Fixture()
        let result = try XCTUnwrap(
            BuildingLocalizationService.locate(
                manuallySelectedNodeID: f.room214, manifest: f.manifest, graph: f.graph
            )
        )
        XCTAssertEqual(result.method, .manualSelection)
        XCTAssertTrue(result.canStartAutomatically)
        XCTAssertEqual(result.routePosition.nodeID, f.room214)
    }

    func testManualRoomListExcludesTheSyntheticStartNode() throws {
        let f = try Fixture()
        var withTemp = f.graph
        withTemp.nodes.append(
            RouteNode(name: "Your Location", type: .temporaryStart, position: at(3, 0), zoneID: f.zoneID)
        )
        let rooms = BuildingLocalizationService.selectableRooms(in: withTemp)
        XCTAssertFalse(rooms.contains { $0.type == .temporaryStart })
        XCTAssertEqual(rooms.count, 3)
    }

    func testSelectingANodeThatIsNotInThisBuildingFails() throws {
        let f = try Fixture()
        XCTAssertNil(
            BuildingLocalizationService.locate(
                manuallySelectedNodeID: UUID(), manifest: f.manifest, graph: f.graph
            )
        )
    }

    // MARK: - A located occupant can route with the existing router

    func testALocalizedPositionRoutesToAnExitThroughTheExistingService() throws {
        let f = try Fixture()
        let located = try XCTUnwrap(
            BuildingLocalizationService.locate(
                worldPosition: SIMD3<Float>(0.2, 1.4, 0),
                relocalizedZoneID: f.zoneID, manifest: f.manifest, graph: f.graph
            )
        )

        let route = try ShortestPathService.findBestEgressRoute(
            from: located.routePosition, graph: f.graph, profile: .standard
        )
        XCTAssertEqual(route.best.destination.id, f.exitID)
    }

    func testDescriptionNamesTheBuildingAndTheNearestPoint() throws {
        let f = try Fixture()
        let located = try XCTUnwrap(
            BuildingLocalizationService.locate(
                worldPosition: SIMD3<Float>(0, 0, 0),
                relocalizedZoneID: f.zoneID, manifest: f.manifest, graph: f.graph
            )
        )
        let text = BuildingLocalizationService.describe(located, manifest: f.manifest)
        XCTAssertTrue(text.contains("Wade Academic Center"))
        XCTAssertTrue(text.contains("Room 214"))
    }
}
