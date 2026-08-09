import Foundation

/// Converts legacy zone data (`waypoints.json` + `path.json`) into a routable
/// `BuildingGraph`. Purely additive — the source files are never rewritten,
/// so a graph can always be regenerated and no saved zone is ever lost.
enum GraphMigrator {

    /// Builds a graph from captured waypoints and the recorded walk.
    /// `RouteNode.id` is deliberately the source `Waypoint.id` so AR anchors,
    /// which are named `wp:<waypoint-uuid>`, keep resolving.
    static func migrate(zoneID: UUID, waypoints: [Waypoint], path: RoutePath) -> BuildingGraph {
        let ordered = waypoints.sorted { $0.pathIndex < $1.pathIndex }

        let nodes = ordered.map { w in
            RouteNode(
                id: w.id,
                name: w.name,
                type: RouteNodeType(w.type),
                position: w.transform,
                zoneID: zoneID
            )
        }

        var edges: [RouteEdge] = []
        guard ordered.count > 1 else {
            return BuildingGraph(zoneID: zoneID, nodes: nodes, edges: edges)
        }

        for i in 1..<ordered.count {
            let a = ordered[i - 1]
            let b = ordered[i]

            // Walking distance around corners is more honest than the
            // straight-line distance through walls.
            let along = alongPathDistance(from: a.pathIndex, to: b.pathIndex, path: path)
            let straight = Double(a.distance(to: b))
            let distance = max(along, straight)

            edges.append(
                RouteEdge(
                    fromNodeID: a.id,
                    toNodeID: b.id,
                    distanceMeters: distance,
                    isBidirectional: true,
                    isBlocked: false,
                    accessibility: .between(RouteNodeType(a.type), RouteNodeType(b.type))
                )
            )
        }

        return BuildingGraph(zoneID: zoneID, nodes: nodes, edges: edges)
    }

    /// Distance actually walked between two indices of the recorded path.
    static func alongPathDistance(from: Int, to: Int, path: RoutePath) -> Double {
        let lo = min(from, to)
        let hi = min(max(from, to), path.points.count - 1)
        guard lo >= 0, hi > lo, path.points.count > 1 else { return 0 }
        var sum = 0.0
        for i in (lo + 1)...hi {
            sum += path.points[i].mapPoint.distance(to: path.points[i - 1].mapPoint)
        }
        return sum
    }

    /// Returns the stored graph when it is current and non-empty, otherwise
    /// rebuilds from source. A corrupt or stale graph is regenerated, never fatal.
    static func resolve(
        stored: BuildingGraph?,
        zoneID: UUID,
        waypoints: [Waypoint],
        path: RoutePath
    ) -> (graph: BuildingGraph, didMigrate: Bool) {
        if let stored, !stored.needsMigration, !stored.isEmpty,
           stored.nodes.count == waypoints.count {
            return (stored, false)
        }
        return (migrate(zoneID: zoneID, waypoints: waypoints, path: path), true)
    }
}
