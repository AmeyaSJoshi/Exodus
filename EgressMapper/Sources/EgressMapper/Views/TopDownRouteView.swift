import SwiftUI

/// Top-down projection of the recorded walk. This is a route sketch, not an
/// architectural floor plan — it shows where you walked, not where walls are.
struct TopDownRouteView: View {
    let path: RoutePath
    let waypoints: [Waypoint]
    var currentPosition: MapPoint?
    var currentHeading: Float = 0
    var highlightedRoute: [RouteNode] = []

    var body: some View {
        Canvas { context, size in
            let points = path.simplified()
            var allPoints = points.map(\.mapPoint) + waypoints.map(\.mapPoint)
            if let currentPosition { allPoints.append(currentPosition) }
            guard !allPoints.isEmpty else { return }

            let bounds = Self.bounds(of: allPoints)
            let transform = Self.fitTransform(bounds: bounds, into: size, padding: 24)

            // Recorded path
            if points.count > 1 {
                var walk = Path()
                walk.move(to: transform(points[0].mapPoint))
                for p in points.dropFirst() { walk.addLine(to: transform(p.mapPoint)) }
                context.stroke(
                    walk,
                    with: .color(.white.opacity(0.35)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
            }

            // Highlighted route on top of the walk
            if highlightedRoute.count > 1 {
                var route = Path()
                route.move(to: transform(highlightedRoute[0].mapPoint))
                for w in highlightedRoute.dropFirst() { route.addLine(to: transform(w.mapPoint)) }
                context.stroke(
                    route,
                    with: .color(.green),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
            }

            // Waypoints
            var labels = EGMapLabelLayout()
            for w in waypoints {
                let p = transform(w.mapPoint)
                let r: CGFloat = 7
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(w.type.tint))
                context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.6)), lineWidth: 1.5)

                context.draw(
                    Text(w.name).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white),
                    at: labels.position(for: w.name, at: p, fontSize: 9)
                )
            }

            // Current position + facing
            if let currentPosition {
                let p = transform(currentPosition)
                let r: CGFloat = 6
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                    with: .color(.cyan)
                )
                // Heading is measured from -Z; in map space that is -Y.
                let len: CGFloat = 18
                let dx = CGFloat(sin(currentHeading)) * len
                let dy = -CGFloat(cos(currentHeading)) * len
                var facing = Path()
                facing.move(to: p)
                facing.addLine(to: CGPoint(x: p.x + dx, y: p.y + dy))
                context.stroke(facing, with: .color(.cyan), lineWidth: 2)
            }
        }
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomTrailing) {
            Text(String(format: "%.0f m walked", path.totalDistance))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }

    // MARK: - Geometry

    struct Bounds {
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double
        var width: Double { max(maxX - minX, 0.001) }
        var height: Double { max(maxY - minY, 0.001) }
    }

    static func bounds(of points: [MapPoint]) -> Bounds {
        var b = Bounds(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
        for p in points {
            b.minX = min(b.minX, p.x)
            b.minY = min(b.minY, p.y)
            b.maxX = max(b.maxX, p.x)
            b.maxY = max(b.maxY, p.y)
        }
        return b
    }

    /// Inverse of `fitTransform` — turns a tap in view space back into map
    /// space so the user can indicate where they are.
    static func inverseFitTransform(bounds: Bounds, into size: CGSize, padding: Double) -> (CGPoint) -> MapPoint {
        let usableW = max(Double(size.width) - padding * 2, 1)
        let usableH = max(Double(size.height) - padding * 2, 1)
        let scale = min(usableW / bounds.width, usableH / bounds.height)
        let offsetX = (Double(size.width) - bounds.width * scale) / 2
        let offsetY = (Double(size.height) - bounds.height * scale) / 2

        return { point in
            guard scale > 1e-9 else { return MapPoint(x: bounds.minX, y: bounds.minY) }
            return MapPoint(
                x: (Double(point.x) - offsetX) / scale + bounds.minX,
                y: (Double(point.y) - offsetY) / scale + bounds.minY
            )
        }
    }

    /// Uniform scale-to-fit that preserves aspect ratio so the sketch is not
    /// stretched into a misleading shape.
    static func fitTransform(bounds: Bounds, into size: CGSize, padding: Double) -> (MapPoint) -> CGPoint {
        let usableW = max(Double(size.width) - padding * 2, 1)
        let usableH = max(Double(size.height) - padding * 2, 1)
        let scale = min(usableW / bounds.width, usableH / bounds.height)
        let offsetX = (Double(size.width) - bounds.width * scale) / 2
        let offsetY = (Double(size.height) - bounds.height * scale) / 2

        return { p in
            CGPoint(
                x: (p.x - bounds.minX) * scale + offsetX,
                y: (p.y - bounds.minY) * scale + offsetY
            )
        }
    }
}
