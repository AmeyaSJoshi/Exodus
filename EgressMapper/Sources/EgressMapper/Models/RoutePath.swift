import Foundation
import simd

struct PathPoint: Codable, Hashable {
    var x: Float
    var y: Float
    var z: Float
    var t: TimeInterval

    init(_ p: SIMD3<Float>, t: TimeInterval) {
        x = p.x
        y = p.y
        z = p.z
        self.t = t
    }

    var position: SIMD3<Float> { SIMD3<Float>(x, y, z) }
    var mapPoint: MapPoint { MapPoint(projecting: position) }
}

/// The recorded walking path. Raw points are retained for diagnostics;
/// `simplified()` is what the top-down view draws.
struct RoutePath: Codable, Hashable {
    var points: [PathPoint] = []

    /// Thresholds governing when a new point is worth recording.
    struct Thresholds {
        var minDistance: Float = 0.25   // metres
        var minRotation: Float = 0.35   // radians (~20°)
        var maxInterval: TimeInterval = 2.0
    }

    var count: Int { points.count }
    var isEmpty: Bool { points.isEmpty }
    var last: PathPoint? { points.last }

    /// Total walked distance in metres, measured on the ground plane so that
    /// normal hand-height bobbing does not inflate the figure.
    var totalDistance: Double {
        guard points.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1..<points.count {
            sum += points[i].mapPoint.distance(to: points[i - 1].mapPoint)
        }
        return sum
    }

    /// Decides whether a new camera pose warrants a recorded point.
    static func shouldRecord(
        newPosition: SIMD3<Float>,
        newHeading: Float,
        lastPosition: SIMD3<Float>?,
        lastHeading: Float?,
        lastTime: TimeInterval?,
        now: TimeInterval,
        thresholds: Thresholds = Thresholds()
    ) -> Bool {
        guard let lastPosition, let lastHeading, let lastTime else { return true }
        if simd_distance(newPosition, lastPosition) >= thresholds.minDistance { return true }
        var dh = abs(newHeading - lastHeading)
        if dh > .pi { dh = 2 * .pi - dh }
        if dh >= thresholds.minRotation { return true }
        if now - lastTime >= thresholds.maxInterval { return true }
        return false
    }

    mutating func append(_ p: SIMD3<Float>, at t: TimeInterval) {
        points.append(PathPoint(p, t: t))
    }

    @discardableResult
    mutating func removeLast() -> PathPoint? {
        points.isEmpty ? nil : points.removeLast()
    }

    /// Ramer–Douglas–Peucker on the ground-plane projection.
    func simplified(epsilon: Double = 0.15) -> [PathPoint] {
        RoutePath.rdp(points, epsilon: epsilon)
    }

    static func rdp(_ pts: [PathPoint], epsilon: Double) -> [PathPoint] {
        guard pts.count > 2 else { return pts }
        let first = pts[0].mapPoint
        let last = pts[pts.count - 1].mapPoint

        var maxDist = 0.0
        var index = 0
        for i in 1..<(pts.count - 1) {
            let d = perpendicularDistance(pts[i].mapPoint, lineStart: first, lineEnd: last)
            if d > maxDist {
                maxDist = d
                index = i
            }
        }

        guard maxDist > epsilon else { return [pts[0], pts[pts.count - 1]] }
        let left = rdp(Array(pts[0...index]), epsilon: epsilon)
        let right = rdp(Array(pts[index...]), epsilon: epsilon)
        return left.dropLast() + right
    }

    static func perpendicularDistance(_ p: MapPoint, lineStart a: MapPoint, lineEnd b: MapPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 1e-12 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        let proj = MapPoint(x: a.x + t * dx, y: a.y + t * dy)
        return p.distance(to: proj)
    }
}
