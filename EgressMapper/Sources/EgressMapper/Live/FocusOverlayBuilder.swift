import CoreLocation
import Foundation

/// Builds the GeoJSON the focus map draws, from a published `BuildingGraph`
/// plus the building's anchor.
///
/// A port of the geometry half of `dashboard/app/focus.tsx`. Constants and
/// semantics are kept identical so a building looks the same on the phone as
/// on the command console.
enum FocusOverlayBuilder {
    static let floorHeightM: Double = 3
    static let slabThicknessM: Double = 0.15
    static let roomHalfWidthM: Double = 1.2
    static let routeBufferM: Double = 0.35
    /// Nodes with no floor recorded (zones mapped before multi-floor) all sit
    /// on one implicit ground floor.
    static let defaultFloorID = "default"

    /// Every distinct floor in the graph, ordered. Matches the dashboard, which
    /// derives floor order by sorting the `floor_id` labels rather than reading
    /// `floors.level` — that column is never populated by the seed data.
    static func floors(in graph: BuildingGraph) -> [String] {
        Array(Set(graph.nodes.map { $0.floorID ?? defaultFloorID })).sorted()
    }

    static func floorIndex(_ floorID: String?, in floors: [String]) -> Int {
        let id = floorID ?? defaultFloorID
        return max(0, floors.firstIndex(of: id) ?? 0)
    }

    // MARK: - Feature collections

    /// Floor slabs: the convex hull of each floor's nodes, extruded thinly so
    /// stacked floors read as distinct planes.
    static func slabs(graph: BuildingGraph, anchor: BuildingAnchor, floors: [String]) -> [[String: Any]] {
        floors.compactMap { floorID -> [String: Any]? in
            let onFloor = graph.nodes.filter { ($0.floorID ?? defaultFloorID) == floorID }
            guard onFloor.count >= 3 else { return nil }
            let points = onFloor.map { coordinate($0, anchor) }
            let hull = convexHull(points)
            guard hull.count >= 3 else { return nil }
            let idx = floorIndex(floorID, in: floors)
            let base = Double(idx) * floorHeightM
            return feature(
                polygon: hull,
                properties: ["floorIdx": idx, "base": base, "top": base + slabThicknessM]
            )
        }
    }

    /// Rooms as synthetic squares — the schema stores points, not footprints,
    /// so this is a stand-in shape rather than captured geometry.
    static func rooms(graph: BuildingGraph, anchor: BuildingAnchor, floors: [String]) -> [[String: Any]] {
        graph.nodes.filter { $0.type == .room }.map { node in
            let p = node.worldPosition
            let x = Double(p.x), z = Double(p.z)
            let corners = [
                (x - roomHalfWidthM, z - roomHalfWidthM),
                (x + roomHalfWidthM, z - roomHalfWidthM),
                (x + roomHalfWidthM, z + roomHalfWidthM),
                (x - roomHalfWidthM, z + roomHalfWidthM),
            ].map { LocalGeo.coordinate(x: $0.0, z: $0.1, scaledBy: anchor) }
            let idx = floorIndex(node.floorID, in: floors)
            let base = Double(idx) * floorHeightM
            return feature(
                polygon: corners,
                properties: ["floorIdx": idx, "base": base, "top": base + floorHeightM]
            )
        }
    }

    /// Escape routes. Fill-extrusion needs a polygon, so each segment is
    /// widened into a ribbon and floated just above its floor.
    ///
    /// The dashboard uses turf's round-join buffer; this builds the rectangle
    /// directly, which is the same shape for a straight two-point segment.
    static func routes(graph: BuildingGraph, anchor: BuildingAnchor, floors: [String]) -> [[String: Any]] {
        graph.edges.compactMap { edge -> [String: Any]? in
            guard let a = graph.node(edge.fromNodeID), let b = graph.node(edge.toNodeID) else { return nil }
            let pa = coordinate(a, anchor)
            let pb = coordinate(b, anchor)
            guard let ribbon = ribbon(from: pa, to: pb, halfWidthM: routeBufferM) else { return nil }
            let idx = floorIndex(a.floorID, in: floors)
            let base = Double(idx) * floorHeightM
            let stepFree = edge.accessibility.wheelchairAccessible && !edge.accessibility.containsStairs
            return feature(
                polygon: ribbon,
                properties: [
                    "floorIdx": idx,
                    "base": base + 0.1,
                    "top": base + 0.4,
                    "stepFree": stepFree,
                ]
            )
        }
    }

    /// Waypoint labels. Hallway points are omitted — they are structure, not
    /// landmarks, and labelling them buries the exits.
    static func labels(graph: BuildingGraph, anchor: BuildingAnchor, floors: [String]) -> [[String: Any]] {
        graph.nodes.filter { $0.type != .hallwayPoint }.map { node in
            let c = coordinate(node, anchor)
            let idx = floorIndex(node.floorID, in: floors)
            let isExit = node.type == .exit
            return [
                "type": "Feature",
                "properties": [
                    "floorIdx": idx,
                    "name": node.name,
                    "isExit": isExit,
                    "label": isExit ? "▲ \(node.name)" : node.name,
                ],
                "geometry": ["type": "Point", "coordinates": [c.longitude, c.latitude]],
            ]
        }
    }

    /// Wraps features into a FeatureCollection ready for `MLNShape`.
    static func collectionData(_ features: [[String: Any]]) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: ["type": "FeatureCollection", "features": features]
        )
    }

    // MARK: - Geometry helpers

    private static func coordinate(_ node: RouteNode, _ anchor: BuildingAnchor) -> CLLocationCoordinate2D {
        let p = node.worldPosition
        return LocalGeo.coordinate(x: Double(p.x), z: Double(p.z), scaledBy: anchor)
    }

    private static func feature(
        polygon ring: [CLLocationCoordinate2D],
        properties: [String: Any]
    ) -> [String: Any] {
        var coords = ring.map { [$0.longitude, $0.latitude] }
        if let first = coords.first { coords.append(first) } // GeoJSON rings close.
        return [
            "type": "Feature",
            "properties": properties,
            "geometry": ["type": "Polygon", "coordinates": [coords]],
        ]
    }

    /// A rectangle of `halfWidthM` either side of the segment. Degrees per
    /// metre differ by axis, so the perpendicular is computed in metres and
    /// converted back per-axis.
    private static func ribbon(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D,
        halfWidthM: Double
    ) -> [CLLocationCoordinate2D]? {
        let latScale = LocalGeo.metersPerDegreeLat
        let lngScale = LocalGeo.metersPerDegreeLat * cos(a.latitude * .pi / 180)

        let dxM = (b.longitude - a.longitude) * lngScale
        let dyM = (b.latitude - a.latitude) * latScale
        let length = (dxM * dxM + dyM * dyM).squareRoot()
        guard length > 0 else { return nil }

        let nxM = -dyM / length * halfWidthM
        let nyM = dxM / length * halfWidthM
        let dLng = nxM / lngScale
        let dLat = nyM / latScale

        return [
            CLLocationCoordinate2D(latitude: a.latitude + dLat, longitude: a.longitude + dLng),
            CLLocationCoordinate2D(latitude: b.latitude + dLat, longitude: b.longitude + dLng),
            CLLocationCoordinate2D(latitude: b.latitude - dLat, longitude: b.longitude - dLng),
            CLLocationCoordinate2D(latitude: a.latitude - dLat, longitude: a.longitude - dLng),
        ]
    }

    /// Monotone chain hull, standing in for turf's `convex`.
    static func convexHull(_ points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard points.count >= 3 else { return points }
        let sorted = points.sorted {
            $0.longitude == $1.longitude ? $0.latitude < $1.latitude : $0.longitude < $1.longitude
        }
        func cross(_ o: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
            (a.longitude - o.longitude) * (b.latitude - o.latitude)
                - (a.latitude - o.latitude) * (b.longitude - o.longitude)
        }
        func build(_ pts: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
            var chain: [CLLocationCoordinate2D] = []
            for p in pts {
                while chain.count >= 2, cross(chain[chain.count - 2], chain[chain.count - 1], p) <= 0 {
                    chain.removeLast()
                }
                chain.append(p)
            }
            chain.removeLast()
            return chain
        }
        return build(sorted) + build(sorted.reversed())
    }
}
