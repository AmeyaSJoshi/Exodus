import Foundation
import simd

/// Works out where the user is on the route graph from a relocalized camera
/// pose. Pure value logic so it is fully unit tested without an AR session.
///
/// Projection happens on the ground plane (X/Z). Camera height varies with how
/// the phone is held, so including Y would add noise, not signal.
enum LocalizationService {

    /// A projected position on one edge.
    struct EdgeProjection: Equatable {
        var edgeID: UUID
        var fraction: Double
        var point: MapPoint
        var distance: Double
    }

    /// Within this radius of an endpoint, report the node itself rather than a
    /// fraction along an edge — "at the stairwell" beats "97% along a hallway".
    static let nodeSnapRadius: Double = 1.0

    /// Beyond this, the user is not meaningfully on the mapped route at all.
    static let maximumUsableDistance: Double = 12.0

    // MARK: - Projection

    /// Closest point on segment a→b to `p`, clamped to the segment.
    static func project(_ p: MapPoint, onto a: MapPoint, _ b: MapPoint) -> (fraction: Double, point: MapPoint, distance: Double) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 1e-9 else {
            return (0, a, p.distance(to: a))
        }

        let raw = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        let t = max(0, min(1, raw))
        let closest = MapPoint(x: a.x + t * dx, y: a.y + t * dy)
        return (t, closest, p.distance(to: closest))
    }

    /// Best projection across every edge in the graph.
    static func nearestEdge(to p: MapPoint, graph: BuildingGraph) -> EdgeProjection? {
        var best: EdgeProjection?
        for edge in graph.edges {
            guard let from = graph.node(edge.fromNodeID),
                  let to = graph.node(edge.toNodeID) else { continue }
            let result = project(p, onto: from.mapPoint, to.mapPoint)
            if best == nil || result.distance < best!.distance {
                best = EdgeProjection(
                    edgeID: edge.id,
                    fraction: result.fraction,
                    point: result.point,
                    distance: result.distance
                )
            }
        }
        return best
    }

    static func nearestNode(to p: MapPoint, graph: BuildingGraph) -> (node: RouteNode, distance: Double)? {
        var best: (RouteNode, Double)?
        for node in graph.nodes where node.type != .temporaryStart {
            let d = p.distance(to: node.mapPoint)
            if best == nil || d < best!.1 { best = (node, d) }
        }
        return best
    }

    // MARK: - Estimate

    /// Turns a relocalized world position into a `LocationEstimate`.
    /// Never claims a position when nothing usable is nearby.
    static func estimate(worldPosition: SIMD3<Float>, graph: BuildingGraph) -> LocationEstimate {
        let here = MapPoint(projecting: worldPosition)

        guard !graph.isEmpty else {
            return LocationEstimate(
                routePosition: RoutePosition(worldPosition: worldPosition),
                nearestNodeName: nil,
                distanceFromRouteMeters: .infinity,
                confidence: .unavailable
            )
        }

        let closestNode = nearestNode(to: here, graph: graph)
        let projection = nearestEdge(to: here, graph: graph)

        // No edges at all (single-waypoint zone) — fall back to node snapping.
        guard let projection else {
            guard let closestNode else {
                return LocationEstimate(
                    routePosition: RoutePosition(worldPosition: worldPosition),
                    nearestNodeName: nil,
                    distanceFromRouteMeters: .infinity,
                    confidence: .unavailable
                )
            }
            return LocationEstimate(
                routePosition: RoutePosition(nodeID: closestNode.node.id, worldPosition: worldPosition),
                nearestNodeName: closestNode.node.name,
                distanceFromRouteMeters: closestNode.distance,
                confidence: usable(closestNode.distance)
                    ? LocationEstimate.confidence(forDistance: closestNode.distance)
                    : .unavailable
            )
        }

        guard usable(projection.distance) else {
            return LocationEstimate(
                routePosition: RoutePosition(worldPosition: worldPosition),
                nearestNodeName: closestNode?.node.name,
                distanceFromRouteMeters: projection.distance,
                confidence: .unavailable
            )
        }

        // Snap to a node when standing essentially on top of one.
        if let closestNode, closestNode.distance <= nodeSnapRadius {
            return LocationEstimate(
                routePosition: RoutePosition(nodeID: closestNode.node.id, worldPosition: worldPosition),
                nearestNodeName: closestNode.node.name,
                distanceFromRouteMeters: closestNode.distance,
                confidence: LocationEstimate.confidence(forDistance: closestNode.distance)
            )
        }

        return LocationEstimate(
            routePosition: RoutePosition(
                edgeID: projection.edgeID,
                fractionAlongEdge: projection.fraction,
                worldPosition: worldPosition
            ),
            nearestNodeName: closestNode?.node.name,
            distanceFromRouteMeters: projection.distance,
            confidence: LocationEstimate.confidence(forDistance: projection.distance)
        )
    }

    static func usable(_ distance: Double) -> Bool {
        distance.isFinite && distance <= maximumUsableDistance
    }

    /// User-facing sentence, e.g. "East Hallway, near Room 214".
    static func describe(_ estimate: LocationEstimate, zone: MappingZone) -> String {
        guard estimate.confidence != .unavailable else {
            return "Your location could not be determined from the map."
        }
        if let name = estimate.nearestNodeName {
            return "\(zone.displayTitle), near \(name)"
        }
        return zone.displayTitle
    }
}
