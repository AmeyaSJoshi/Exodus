import Foundation
import simd

/// A 2D point in top-down map space (world X/Z projected to the ground plane).
struct MapPoint: Codable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// ARKit world space is Y-up, so the floor plane is X/Z.
    init(projecting p: SIMD3<Float>) {
        x = Double(p.x)
        y = Double(p.z)
    }

    func distance(to other: MapPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }

    static let zero = MapPoint(x: 0, y: 0)
}

struct Waypoint: Codable, Identifiable, Hashable {
    var id: UUID
    var zoneID: UUID
    var name: String
    var type: WaypointType
    /// Identifier of the `ARAnchor` persisted inside the `ARWorldMap`.
    var anchorID: UUID
    var transform: CodableTransform
    var mapPoint: MapPoint
    /// Index into the recorded path at the moment of capture. Used to derive
    /// route-graph edges from walk order.
    var pathIndex: Int
    var createdAt: Date
    var detectedText: String?
    var notes: String?

    init(
        id: UUID = UUID(),
        zoneID: UUID,
        name: String,
        type: WaypointType,
        anchorID: UUID,
        transform: CodableTransform,
        pathIndex: Int,
        createdAt: Date = Date(),
        detectedText: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.zoneID = zoneID
        self.name = name
        self.type = type
        self.anchorID = anchorID
        self.transform = transform
        self.mapPoint = MapPoint(projecting: transform.position)
        self.pathIndex = pathIndex
        self.createdAt = createdAt
        self.detectedText = detectedText
        self.notes = notes
    }

    var position: SIMD3<Float> { transform.position }

    func distance(to other: Waypoint) -> Float {
        simd_distance(position, other.position)
    }
}
