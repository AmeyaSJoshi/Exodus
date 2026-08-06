import Foundation

/// Metadata describing one mapped indoor zone. Persisted as `zone.json`.
/// Deliberately small — waypoints, path and world map live in sibling files
/// so a corrupt world map cannot make the zone unlistable.
struct MappingZone: Codable, Identifiable, Hashable {
    var id: UUID
    var campus: String
    var building: String
    var floor: String
    var zoneName: String
    var createdAt: Date
    var updatedAt: Date

    // Denormalised summary so the zone list renders without loading everything.
    var waypointCount: Int
    var pathLength: Double
    var hasWorldMap: Bool
    var hasFloorPlan: Bool
    var hasReferenceImage: Bool

    init(
        id: UUID = UUID(),
        campus: String,
        building: String,
        floor: String,
        zoneName: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        waypointCount: Int = 0,
        pathLength: Double = 0,
        hasWorldMap: Bool = false,
        hasFloorPlan: Bool = false,
        hasReferenceImage: Bool = false
    ) {
        self.id = id
        self.campus = campus
        self.building = building
        self.floor = floor
        self.zoneName = zoneName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.waypointCount = waypointCount
        self.pathLength = pathLength
        self.hasWorldMap = hasWorldMap
        self.hasFloorPlan = hasFloorPlan
        self.hasReferenceImage = hasReferenceImage
    }

    var displayTitle: String { zoneName.isEmpty ? "Untitled Zone" : zoneName }
    var displaySubtitle: String { "\(building) · \(floor)" }
    var groupKey: String { "\(campus)|\(building)|\(floor)" }

    var formattedLength: String {
        String(format: "%.0f m", pathLength)
    }
}
