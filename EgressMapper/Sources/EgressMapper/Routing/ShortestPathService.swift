import Foundation

/// Deterministic shortest-path routing over a `BuildingGraph`.
/// No language model is involved in any routing decision.
enum ShortestPathService {

    /// An edge is either traversable or it is not. Blocked and
    /// profile-violating edges are removed from the search space entirely —
    /// they are never given a large finite cost that a desperate search could
    /// still choose.
    static func isTraversable(_ edge: RouteEdge, profile: NavigationProfile) -> Bool {
        if edge.isImpassable { return false }
        if profile.avoidStairs && edge.accessibility.containsStairs { return false }
        if profile.requireWheelchairAccessible && !edge.accessibility.wheelchairAccessible { return false }
        if profile.avoidElevators && edge.accessibility.requiresElevator { return false }
        return true
    }

    static func cost(_ edge: RouteEdge) -> Double {
        max(edge.distanceMeters, 0.01) * edge.hazardPenalty
    }

    // MARK: - Single destination

    static func findRoute(
        from start: RoutePosition,
        to destinationNodeID: UUID,
        graph: BuildingGraph,
        profile: NavigationProfile
    ) throws -> CalculatedRoute {
        guard !graph.isEmpty else { throw RoutingError.emptyGraph }

        let (searchGraph, startNodeID) = try resolveStart(start, in: graph)
        guard searchGraph.node(destinationNodeID) != nil else { throw RoutingError.unknownDestination }

        guard let result = dijkstra(
            from: startNodeID, to: destinationNodeID, graph: searchGraph, profile: profile
        ) else {
            throw profile.hasAccessibilityConstraints
                ? RoutingError.noAccessibleRoute(constraints: profile.constraintSummary ?? "")
                : RoutingError.noRoute
        }

        guard let destination = searchGraph.node(destinationNodeID) else {
            throw RoutingError.unknownDestination
        }

        return CalculatedRoute(
            nodes: result.nodes,
            edges: result.edges,
            totalDistanceMeters: result.cost,
            destination: destination,
            explanation: explanation(to: destination, distance: result.cost, profile: profile),
            isRefugeFallback: destination.type.isRefuge
        )
    }

    /// An exit that exists on the map but cannot be routed to right now.
    struct UnreachableExit: Hashable {
        var node: RouteNode
        var reason: String
    }

    /// Every egress option, ranked, plus the exits that had to be ruled out.
    struct EgressOptions {
        var best: CalculatedRoute
        var alternatives: [CalculatedRoute]
        var unreachable: [UnreachableExit]

        /// e.g. "Routing to West Exit — 64 m. East Exit is unavailable."
        var summary: String {
            var text = best.explanation
            if !unreachable.isEmpty {
                let names = unreachable.map(\.node.name)
                let list = names.count == 1
                    ? names[0]
                    : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
                text += " \(list) \(names.count == 1 ? "is" : "are") unavailable."
            }
            return text
        }
    }

    /// Evaluates every exit and returns the cheapest reachable one, falling
    /// back to an area of refuge when no exit can be reached.
    static func findBestEgressRoute(
        from start: RoutePosition,
        graph: BuildingGraph,
        profile: NavigationProfile
    ) throws -> EgressOptions {
        guard !graph.isEmpty else { throw RoutingError.emptyGraph }

        var routes: [CalculatedRoute] = []
        var unreachable: [UnreachableExit] = []

        for exit in graph.exits {
            do {
                routes.append(try findRoute(from: start, to: exit.id, graph: graph, profile: profile))
            } catch {
                unreachable.append(
                    UnreachableExit(node: exit, reason: error.localizedDescription)
                )
            }
        }

        if routes.isEmpty {
            // No exit reachable — shelter beats stranding the user.
            for refuge in graph.refuges {
                if let route = try? findRoute(from: start, to: refuge.id, graph: graph, profile: profile) {
                    routes.append(route)
                }
            }
        }

        guard !routes.isEmpty else {
            throw profile.hasAccessibilityConstraints
                ? RoutingError.noAccessibleRoute(constraints: profile.constraintSummary ?? "")
                : RoutingError.noRoute
        }

        routes.sort { $0.totalDistanceMeters < $1.totalDistanceMeters }
        return EgressOptions(
            best: routes[0],
            alternatives: Array(routes.dropFirst()),
            unreachable: unreachable
        )
    }

    // MARK: - Start resolution

    /// Turns a `RoutePosition` into a node the search can start from,
    /// synthesising a temporary node when the user is mid-edge.
    static func resolveStart(
        _ start: RoutePosition,
        in graph: BuildingGraph
    ) throws -> (BuildingGraph, UUID) {
        if let nodeID = start.nodeID {
            guard graph.node(nodeID) != nil else { throw RoutingError.unknownStart }
            return (graph, nodeID)
        }
        if let edgeID = start.edgeID {
            let fraction = start.fractionAlongEdge ?? 0.5
            guard let inserted = graph.insertingTemporaryStart(onEdge: edgeID, fraction: fraction) else {
                throw RoutingError.unknownStart
            }
            return (inserted.graph, inserted.startNodeID)
        }
        throw RoutingError.unknownStart
    }

    // MARK: - Dijkstra

    private struct SearchResult {
        var nodes: [RouteNode]
        var edges: [RouteEdge]
        var cost: Double
    }

    private static func dijkstra(
        from startID: UUID,
        to endID: UUID,
        graph: BuildingGraph,
        profile: NavigationProfile
    ) -> SearchResult? {
        if startID == endID, let node = graph.node(startID) {
            return SearchResult(nodes: [node], edges: [], cost: 0)
        }

        // Adjacency limited to traversable edges only.
        var adjacency: [UUID: [(to: UUID, edge: RouteEdge)]] = [:]
        for edge in graph.edges where isTraversable(edge, profile: profile) {
            adjacency[edge.fromNodeID, default: []].append((edge.toNodeID, edge))
            if edge.isBidirectional {
                adjacency[edge.toNodeID, default: []].append((edge.fromNodeID, edge))
            }
        }

        var dist: [UUID: Double] = [startID: 0]
        var prev: [UUID: (node: UUID, edge: RouteEdge)] = [:]
        var visited: Set<UUID> = []
        var frontier: [(id: UUID, d: Double)] = [(startID, 0)]

        while !frontier.isEmpty {
            frontier.sort { $0.d < $1.d }
            let current = frontier.removeFirst()
            if visited.contains(current.id) { continue }
            visited.insert(current.id)
            if current.id == endID { break }

            for (next, edge) in adjacency[current.id] ?? [] where !visited.contains(next) {
                let candidate = current.d + cost(edge)
                if candidate < (dist[next] ?? .greatestFiniteMagnitude) {
                    dist[next] = candidate
                    prev[next] = (current.id, edge)
                    frontier.append((next, candidate))
                }
            }
        }

        guard let total = dist[endID] else { return nil }

        var nodeChain: [UUID] = [endID]
        var edgeChain: [RouteEdge] = []
        var cursor = endID
        while cursor != startID {
            guard let step = prev[cursor] else { return nil }
            edgeChain.append(step.edge)
            nodeChain.append(step.node)
            cursor = step.node
        }

        let nodes = nodeChain.reversed().compactMap { graph.node($0) }
        guard nodes.count == nodeChain.count else { return nil }
        return SearchResult(nodes: nodes, edges: edgeChain.reversed(), cost: total)
    }

    // MARK: - Explanation

    static func explanation(to destination: RouteNode, distance: Double, profile: NavigationProfile) -> String {
        var text = "Routing to \(destination.name) — \(Int(distance.rounded())) m"
        if let constraints = profile.constraintSummary {
            text += " (\(constraints))"
        }
        if destination.type.isRefuge {
            text += ". No exit is reachable, so this routes to an area of refuge."
        }
        return text + "."
    }
}
