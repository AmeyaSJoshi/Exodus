import Foundation
import CoreGraphics

/// 2D similarity transform (uniform scale + rotation + translation) mapping
/// recorded map space onto floor-plan image pixels.
struct FloorPlanAlignment: Codable, Hashable {
    var scale: Double
    var rotation: Double      // radians
    var translationX: Double
    var translationY: Double
    /// Residual error in pixels, so the UI can be honest about fit quality.
    var rmsError: Double

    static let identity = FloorPlanAlignment(
        scale: 1, rotation: 0, translationX: 0, translationY: 0, rmsError: 0
    )

    func apply(_ p: MapPoint) -> CGPoint {
        let c = cos(rotation), s = sin(rotation)
        return CGPoint(
            x: scale * (c * p.x - s * p.y) + translationX,
            y: scale * (s * p.x + c * p.y) + translationY
        )
    }

    /// Inverse mapping, for turning a tap on the plan back into map space.
    func invert(_ point: CGPoint) -> MapPoint {
        guard scale > 1e-9 else { return .zero }
        let dx = Double(point.x) - translationX
        let dy = Double(point.y) - translationY
        let c = cos(-rotation), s = sin(-rotation)
        return MapPoint(
            x: (c * dx - s * dy) / scale,
            y: (s * dx + c * dy) / scale
        )
    }
}

enum FloorPlanAlignmentError: LocalizedError {
    case notEnoughPoints
    case degeneratePoints

    var errorDescription: String? {
        switch self {
        case .notEnoughPoints:
            return "Pick at least two matching points to align the floor plan."
        case .degeneratePoints:
            return "The selected points are too close together. Pick points far apart, ideally at opposite ends of the hallway."
        }
    }
}

/// Least-squares similarity fit (Procrustes). Works for 2 correspondences and
/// improves with 3+. Isolated here so it is testable without any UI.
enum FloorPlanAlignmentService {

    struct Correspondence {
        var mapPoint: MapPoint   // recorded space
        var planPoint: CGPoint   // floor-plan image pixels
    }

    static func solve(_ pairs: [Correspondence]) throws -> FloorPlanAlignment {
        guard pairs.count >= 2 else { throw FloorPlanAlignmentError.notEnoughPoints }

        let n = Double(pairs.count)
        let srcMeanX = pairs.map(\.mapPoint.x).reduce(0, +) / n
        let srcMeanY = pairs.map(\.mapPoint.y).reduce(0, +) / n
        let dstMeanX = pairs.map { Double($0.planPoint.x) }.reduce(0, +) / n
        let dstMeanY = pairs.map { Double($0.planPoint.y) }.reduce(0, +) / n

        var sumNum = 0.0     // cross term  -> sin
        var sumDen = 0.0     // dot term    -> cos
        var srcNorm = 0.0
        var dstNorm = 0.0

        for pair in pairs {
            let px = pair.mapPoint.x - srcMeanX
            let py = pair.mapPoint.y - srcMeanY
            let qx = Double(pair.planPoint.x) - dstMeanX
            let qy = Double(pair.planPoint.y) - dstMeanY

            sumNum += px * qy - py * qx
            sumDen += px * qx + py * qy
            srcNorm += px * px + py * py
            dstNorm += qx * qx + qy * qy
        }

        guard srcNorm > 1e-9, dstNorm > 1e-9 else {
            throw FloorPlanAlignmentError.degeneratePoints
        }

        let rotation = atan2(sumNum, sumDen)
        let scale = (dstNorm / srcNorm).squareRoot()

        let c = cos(rotation), s = sin(rotation)
        let tx = dstMeanX - scale * (c * srcMeanX - s * srcMeanY)
        let ty = dstMeanY - scale * (s * srcMeanX + c * srcMeanY)

        var alignment = FloorPlanAlignment(
            scale: scale, rotation: rotation,
            translationX: tx, translationY: ty, rmsError: 0
        )
        alignment.rmsError = rms(alignment, pairs)
        return alignment
    }

    static func rms(_ alignment: FloorPlanAlignment, _ pairs: [Correspondence]) -> Double {
        guard !pairs.isEmpty else { return 0 }
        var total = 0.0
        for pair in pairs {
            let projected = alignment.apply(pair.mapPoint)
            let dx = Double(projected.x - pair.planPoint.x)
            let dy = Double(projected.y - pair.planPoint.y)
            total += dx * dx + dy * dy
        }
        return (total / Double(pairs.count)).squareRoot()
    }
}
