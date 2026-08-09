import SwiftUI

/// The 2D evacuation map.
///
/// Same graph, same coordinates and same router as every other surface — this
/// is presentation only. What changed is what it is *for*: someone moving
/// through a building needs to see where they are, where they are going, and
/// what is closed, not a faithful rendering of every node in the graph.
///
/// Hallway points are drawn as structure rather than labelled landmarks, the
/// active route is the most prominent thing on screen, alternative exits are
/// present but quiet, and closures are dashed and badged so they do not depend
/// on colour alone.
struct EvacuationMapView: View {
    let graph: BuildingGraph
    /// The route being followed, in order. Empty is valid — the map still shows
    /// the building and where the exits are.
    var route: [RouteNode] = []
    /// Where the user is. A node id when they are at a known point.
    var currentNodeID: UUID?
    /// Live position from AR, when there is one. Wins over `currentNodeID`.
    var currentPoint: MapPoint?
    /// Radians, measured from -Z as ARKit reports it.
    var heading: Double?
    /// The next point to reach, highlighted separately from the destination.
    var nextNodeID: UUID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var routeIDs: Set<UUID> { Set(route.map(\.id)) }
    private var destination: RouteNode? { route.last }

    /// Exits that are not the current destination. Drawn, but never competing
    /// with where the person is actually being sent.
    private var otherExits: [RouteNode] {
        graph.nodes.filter { $0.type.isEgressTarget && $0.id != destination?.id }
    }

    var body: some View {
        Canvas { context, size in
            let points = graph.nodes.map(\.mapPoint)
            guard !points.isEmpty else { return }
            let bounds = TopDownRouteView.bounds(of: points)
            let t = TopDownRouteView.fitTransform(bounds: bounds, into: size, padding: 40)

            drawStructure(context: context, transform: t)
            drawClosures(context: context, transform: t)
            drawRoute(context: context, transform: t)
            drawNodes(context: context, transform: t, canvas: size)
            drawUser(context: context, transform: t)
        }
        .background(Color.black.opacity(0.55))
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    /// VoiceOver gets the same information the drawing carries, in a sentence.
    private var accessibilitySummary: String {
        var parts: [String] = ["Evacuation map"]
        if let destination { parts.append("routing to \(destination.name)") }
        let closed = graph.edges.filter(\.isImpassable).count
        if closed > 0 { parts.append("\(closed) segment\(closed == 1 ? "" : "s") closed") }
        if !otherExits.isEmpty {
            parts.append("other exits: \(otherExits.map(\.name).joined(separator: ", "))")
        }
        return parts.joined(separator: ". ")
    }

    // MARK: - Layers

    /// Everything passable that is not on the route. Deliberately faint: it is
    /// context, not instruction.
    private func drawStructure(context: GraphicsContext, transform t: (MapPoint) -> CGPoint) {
        for edge in graph.edges where !edge.isImpassable {
            guard let a = graph.node(edge.fromNodeID), let b = graph.node(edge.toNodeID) else { continue }
            let onRoute = routeIDs.contains(edge.fromNodeID) && routeIDs.contains(edge.toNodeID)
            guard !onRoute else { continue }
            var line = Path()
            line.move(to: t(a.mapPoint))
            line.addLine(to: t(b.mapPoint))
            // A discouraged segment is passable, so it stays solid — it is
            // simply dimmer than the rest of the structure.
            let discouraged = edge.hazardPenalty > 1
            context.stroke(
                line,
                with: .color(.white.opacity(discouraged ? 0.14 : 0.26)),
                style: StrokeStyle(lineWidth: 6, lineCap: .round)
            )
        }
    }

    /// Closed segments: dashed, red, and crossed through. Three signals, so
    /// none of them has to be colour.
    private func drawClosures(context: GraphicsContext, transform t: (MapPoint) -> CGPoint) {
        for edge in graph.edges where edge.isImpassable {
            guard let a = graph.node(edge.fromNodeID), let b = graph.node(edge.toNodeID) else { continue }
            let p1 = t(a.mapPoint)
            let p2 = t(b.mapPoint)
            var line = Path()
            line.move(to: p1)
            line.addLine(to: p2)
            context.stroke(
                line,
                with: .color(.egEmergency),
                style: StrokeStyle(lineWidth: 4, lineCap: .butt, dash: [7, 6])
            )

            let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            context.fill(
                Path(ellipseIn: CGRect(x: mid.x - 9, y: mid.y - 9, width: 18, height: 18)),
                with: .color(.black.opacity(0.85))
            )
            context.stroke(
                Path(ellipseIn: CGRect(x: mid.x - 9, y: mid.y - 9, width: 18, height: 18)),
                with: .color(.egEmergency), lineWidth: 2
            )
            context.draw(
                Text(Image(systemName: "xmark")).font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.egEmergency),
                at: mid
            )
        }
    }

    /// The active route. The one thing on the map that should be unmissable.
    private func drawRoute(context: GraphicsContext, transform t: (MapPoint) -> CGPoint) {
        guard route.count > 1 else { return }
        var path = Path()
        path.move(to: t(route[0].mapPoint))
        for node in route.dropFirst() { path.addLine(to: t(node.mapPoint)) }

        context.stroke(path, with: .color(.egSafe.opacity(0.25)),
                       style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(.egSafe),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))

        // Direction chevrons along each leg, so the line reads as travel rather
        // than as a connection.
        for index in 0..<(route.count - 1) {
            let p1 = t(route[index].mapPoint)
            let p2 = t(route[index + 1].mapPoint)
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let length = max(sqrt(dx * dx + dy * dy), 0.001)
            guard length > 28 else { continue }
            let ux = dx / length
            let uy = dy / length
            let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            let size: CGFloat = 6
            var chevron = Path()
            chevron.move(to: CGPoint(x: mid.x - ux * size + uy * size, y: mid.y - uy * size - ux * size))
            chevron.addLine(to: CGPoint(x: mid.x + ux * size, y: mid.y + uy * size))
            chevron.addLine(to: CGPoint(x: mid.x - ux * size - uy * size, y: mid.y - uy * size + ux * size))
            context.stroke(chevron, with: .color(.black.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawNodes(context: GraphicsContext, transform t: (MapPoint) -> CGPoint, canvas: CGSize) {
        var labels = EGMapLabelLayout()

        for node in graph.nodes {
            // Hallway points are geometry, not destinations. Drawing and naming
            // every one of them is what made this read as a graph dump.
            guard node.type != .hallwayPoint else { continue }
            let p = t(node.mapPoint)
            let isDestination = node.id == destination?.id
            let isNext = node.id == nextNodeID
            let onRoute = routeIDs.contains(node.id)
            let radius: CGFloat = isDestination ? 11 : node.type.isEgressTarget ? 8 : onRoute ? 7 : 5

            if isDestination {
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34)),
                    with: .color(.egSafe.opacity(0.22))
                )
            }
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(tint(for: node, onRoute: onRoute))
            )
            if isNext {
                context.stroke(
                    Path(ellipseIn: CGRect(x: p.x - radius - 4, y: p.y - radius - 4,
                                           width: radius * 2 + 8, height: radius * 2 + 8)),
                    with: .color(.white), lineWidth: 2
                )
            }

            // Name the places a person navigates by, and stay quiet about the
            // rest so the map does not fill with text.
            let worthNaming = node.type.isEgressTarget || node.type.isRefuge
                || onRoute || node.type == .stairwell || node.type == .elevator
            guard worthNaming else { continue }

            let caption = isDestination ? "\(node.name) — exit" : node.name
            context.draw(
                Text(caption)
                    .font(.system(size: isDestination ? 11 : 9,
                                  weight: isDestination ? .bold : .semibold))
                    .foregroundStyle(.white),
                at: labels.position(for: caption, at: p, fontSize: isDestination ? 11 : 9, within: canvas)
            )
        }
    }

    private func tint(for node: RouteNode, onRoute: Bool) -> Color {
        if node.id == destination?.id { return .egSafe }
        if node.type.isEgressTarget { return .egSafe.opacity(0.45) }
        if onRoute { return .white.opacity(0.85) }
        return node.type.tint.opacity(0.7)
    }

    /// "You are here". Drawn last so nothing can sit on top of it.
    private func drawUser(context: GraphicsContext, transform t: (MapPoint) -> CGPoint) {
        let point: MapPoint?
        if let currentPoint {
            point = currentPoint
        } else if let currentNodeID, let node = graph.node(currentNodeID) {
            point = node.mapPoint
        } else {
            point = nil
        }
        guard let point else { return }
        let p = t(point)

        context.fill(
            Path(ellipseIn: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)),
            with: .color(.white.opacity(0.18))
        )
        context.fill(
            Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)),
            with: .color(.white)
        )
        context.stroke(
            Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)),
            with: .color(.black.opacity(0.6)), lineWidth: 2
        )

        if let heading {
            // ARKit measures heading from -Z, which is -Y in map space.
            let length: CGFloat = 22
            let dx = CGFloat(sin(heading)) * length
            let dy = -CGFloat(cos(heading)) * length
            var facing = Path()
            facing.move(to: p)
            facing.addLine(to: CGPoint(x: p.x + dx, y: p.y + dy))
            context.stroke(facing, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }

        context.draw(
            Text("You").font(.system(size: 9, weight: .bold)).foregroundStyle(.white),
            at: CGPoint(x: p.x, y: p.y + 26)
        )
    }
}

/// The map plus the two numbers someone actually needs while moving.
struct EvacuationMapPanel: View {
    let graph: BuildingGraph
    var route: [RouteNode] = []
    var currentNodeID: UUID?
    var currentPoint: MapPoint?
    var heading: Double?
    var nextNodeID: UUID?
    /// Metres to the next point, when guidance is running.
    var distanceToNext: Double?
    var remainingDistance: Double?

    var body: some View {
        VStack(spacing: 0) {
            EvacuationMapView(
                graph: graph, route: route,
                currentNodeID: currentNodeID, currentPoint: currentPoint,
                heading: heading, nextNodeID: nextNodeID
            )

            if distanceToNext != nil || remainingDistance != nil || route.count > 1 {
                HStack(spacing: EG.Space.l) {
                    if let nextNodeID, let next = graph.node(nextNodeID) {
                        Label {
                            Text(distanceToNext.map { String(format: "%.0f m to %@", $0, next.name) }
                                 ?? "Next: \(next.name)")
                        } icon: {
                            Image(systemName: "arrow.turn.up.right")
                        }
                    }
                    Spacer(minLength: 0)
                    if let remainingDistance {
                        Label(String(format: "%.0f m left", remainingDistance), systemImage: "flag.checkered")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, EG.Space.m)
                .padding(.vertical, EG.Space.s)
                .background(Color.egSurface)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: EG.Radius.card))
    }
}
