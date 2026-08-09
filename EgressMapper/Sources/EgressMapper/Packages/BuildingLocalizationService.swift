import Foundation
import simd

/// Works out where an occupant is *inside one selected building*, using only
/// that building's downloaded localization package.
///
/// The rule this enforces: normal AR tracking is not localization. A position
/// is only claimed when it is tied to a mapping zone that was relocalized
/// against, or to a checkpoint recognised from a sign. Everything else falls
/// through to manual room selection.
enum BuildingLocalizationService {

    /// How the position was arrived at. Shown to the user, because "I read the
    /// sign on the door" and "I matched the room's 3D map" deserve different
    /// trust.
    enum Method: String, Hashable {
        case worldMapRelocalization
        case signRecognition
        case manualSelection

        var displayName: String {
            switch self {
            case .worldMapRelocalization: return "Matched the saved map of this area"
            case .signRecognition: return "Read a room sign"
            case .manualSelection: return "You chose this location"
            }
        }
    }

    struct Result: Equatable {
        var routePosition: RoutePosition
        var estimate: LocationEstimate
        var method: Method
        var zoneID: UUID?
        var matchedText: String?

        var confidence: LocationConfidence { estimate.confidence }
        /// Low-confidence results still get shown, but never start a route on
        /// their own — the user has to confirm or pick manually.
        var canStartAutomatically: Bool { estimate.confidence.allowsAutomaticNavigation }
    }

    // MARK: - Candidate zones

    /// The mapping zones worth attempting, for this building only. Zones with
    /// no ARWorldMap cannot be relocalized against and are skipped, but their
    /// nodes remain available for sign matching and manual selection.
    static func relocalizableZones(in manifest: MapPackageManifest) -> [PackageZone] {
        manifest.zones.filter(\.hasWorldMap)
    }

    /// Reference photographs to show while scanning, newest guidance first.
    /// Several viewpoints per zone is what makes relocalization work from more
    /// than the one angle the zone was recorded from.
    static func referenceArtifacts(
        for zone: PackageZone, in manifest: MapPackageManifest
    ) -> [PackageArtifact] {
        zone.referenceImageArtifactIDs.compactMap { manifest.artifact($0) }
    }

    /// What to tell the user to do. Concrete beats encouraging.
    static func scanInstructions(for zone: PackageZone, in manifest: MapPackageManifest) -> String {
        let views = referenceArtifacts(for: zone, in: manifest)
        let described = views.compactMap(\.viewpoint).filter { !$0.isEmpty }
        if described.isEmpty {
            return "Stand still and sweep the camera slowly across the walls and doorways around you."
        }
        if described.count == 1 {
            return "Face \(described[0]) and sweep the camera slowly across the wall."
        }
        return "Sweep the camera slowly across the area. Any of these views works: "
            + described.joined(separator: ", ") + "."
    }

    // MARK: - Relocalized position

    /// Turns a relocalized camera pose into a position on the building's graph.
    ///
    /// - Parameter relocalizedZoneID: the zone whose ARWorldMap ARKit actually
    ///   matched. Passing nil means tracking is merely normal, which is not
    ///   localization and yields no result.
    static func locate(
        worldPosition: SIMD3<Float>,
        relocalizedZoneID: UUID?,
        manifest: MapPackageManifest,
        graph: BuildingGraph
    ) -> Result? {
        guard let zoneID = relocalizedZoneID, manifest.zone(zoneID) != nil else { return nil }

        // Only nodes belonging to the relocalized zone are candidates: a pose
        // from one zone's coordinate space means nothing in another's.
        let scoped = restrict(graph, toZone: zoneID, manifest: manifest)
        guard !scoped.isEmpty else { return nil }

        let estimate = LocalizationService.estimate(worldPosition: worldPosition, graph: scoped)
        guard estimate.confidence != .unavailable else { return nil }

        return Result(
            routePosition: estimate.routePosition,
            estimate: estimate,
            method: .worldMapRelocalization,
            zoneID: zoneID,
            matchedText: nil
        )
    }

    /// The subgraph belonging to one mapping zone.
    static func restrict(
        _ graph: BuildingGraph, toZone zoneID: UUID, manifest: MapPackageManifest
    ) -> BuildingGraph {
        guard let zone = manifest.zone(zoneID) else { return graph }
        let allowed = Set(zone.nodeStableIDs)
        // A single-zone package needs no filtering, and filtering it would only
        // risk dropping nodes if the zone index were incomplete.
        guard manifest.zones.count > 1 else { return graph }

        let nodes = graph.nodes.filter { allowed.contains($0.id) }
        let edges = graph.edges.filter {
            allowed.contains($0.fromNodeID) && allowed.contains($0.toNodeID)
        }
        return BuildingGraph(zoneID: zoneID, nodes: nodes, edges: edges)
    }

    // MARK: - Sign recognition

    /// Resolves OCR text against this building's room numbers and aliases.
    ///
    /// Matching is exact-after-normalisation on purpose: guessing that "Room
    /// 214" is near enough to "Room 244" would send someone the wrong way.
    static func locate(
        recognizedText candidates: [String],
        manifest: MapPackageManifest,
        graph: BuildingGraph
    ) -> Result? {
        let index = manifest.aliasIndex

        for raw in candidates {
            let normalized = MapPackageManifest.normalize(raw)
            guard !normalized.isEmpty else { continue }

            var matchedID = index[normalized]
            // A sign often reads just "214" while the node is "Room 214".
            // Restricted to bare numbers: a word suffix would let a sign
            // reading "EXIT" match "East Exit" and point someone at the wrong
            // end of the building.
            if matchedID == nil, normalized.allSatisfy(\.isNumber) {
                let suffix = " \(normalized)"
                let nodes = Set(index.filter { $0.key.hasSuffix(suffix) }.map(\.value))
                // Ambiguous — "214" matching both Room 214 and Lab 214 — is no
                // match at all.
                matchedID = nodes.count == 1 ? nodes.first : nil
            }

            guard let nodeID = matchedID, let node = graph.node(nodeID) else { continue }

            let estimate = LocationEstimate(
                routePosition: RoutePosition(nodeID: node.id, worldPosition: node.worldPosition),
                nearestNodeName: node.name,
                distanceFromRouteMeters: 0,
                // A read sign names the room outright — as good as it gets
                // without a 3D match, but it says nothing about which end of
                // the room the reader is standing at.
                confidence: .high
            )
            return Result(
                routePosition: estimate.routePosition,
                estimate: estimate,
                method: .signRecognition,
                zoneID: manifest.nodes.first { $0.stableID == nodeID }?.zoneID,
                matchedText: raw
            )
        }
        return nil
    }

    // MARK: - Manual fallback

    /// Always available, and always the answer when nothing else worked.
    static func locate(
        manuallySelectedNodeID nodeID: UUID, manifest: MapPackageManifest, graph: BuildingGraph
    ) -> Result? {
        guard let node = graph.node(nodeID) else { return nil }
        let estimate = LocationEstimate(
            routePosition: RoutePosition(nodeID: node.id, worldPosition: node.worldPosition),
            nearestNodeName: node.name,
            distanceFromRouteMeters: 0,
            confidence: .high
        )
        return Result(
            routePosition: estimate.routePosition,
            estimate: estimate,
            method: .manualSelection,
            zoneID: manifest.nodes.first { $0.stableID == nodeID }?.zoneID,
            matchedText: nil
        )
    }

    /// Rooms an occupant can pick from, for the manual fallback.
    static func selectableRooms(in graph: BuildingGraph) -> [RouteNode] {
        graph.nodes
            .filter { $0.type != .temporaryStart }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One sentence describing where the user has been placed.
    static func describe(_ result: Result, manifest: MapPackageManifest) -> String {
        let place = result.estimate.nearestNodeName ?? manifest.buildingName
        if let zoneID = result.zoneID, let zone = manifest.zone(zoneID), zone.name != place {
            return "\(manifest.buildingName) — \(zone.name), near \(place)"
        }
        return "\(manifest.buildingName) — near \(place)"
    }
}
