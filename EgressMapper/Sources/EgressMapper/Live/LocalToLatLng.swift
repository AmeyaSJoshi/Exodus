import CoreLocation
import Foundation

/// Local AR metres -> real-world coordinates, using a building's georeference
/// anchor (the `anchor_lat`/`anchor_lng`/`heading_deg` columns added in
/// 20260806000900_building_georeference.sql).
///
/// A direct port of `dashboard/lib/geo.ts`; the dashboard's focus view and this
/// app must place the same node in the same place, so the arithmetic is kept
/// identical rather than re-derived.
///
/// `Waypoint`/`RouteNode` positions are ARKit world space: X is right, Y is up
/// (capture height — handled separately as floor altitude), Z is *toward* the
/// camera, so -Z is "forward" from wherever the mapper faced when the session
/// started. ARKit does not know compass heading unless the session opts into
/// `.gravityAndHeading`, which `ARSessionManager` does not — so the initial
/// forward is arbitrary, and `headingDeg` is exactly that missing piece: the
/// compass bearing (clockwise from true north) that local forward pointed to.
enum LocalGeo {
    /// Metres per degree of latitude. Constant here — accurate to within
    /// centimetres over the span of a single building.
    static let metersPerDegreeLat: Double = 111_320

    /// - Parameters:
    ///   - x: Local metres along the building's local +X (right) axis.
    ///   - y: Local metres along the local *planar* depth axis — callers pass
    ///     `position.z`, never `position.y` (AR height). Named `y` because this
    ///     is a generic 2D local-to-geo transform; the z-vs-height distinction
    ///     lives at the call site.
    ///   - anchor: The building's real-world anchor.
    static func coordinate(x: Double, y: Double, anchor: BuildingAnchor) -> CLLocationCoordinate2D {
        let theta = anchor.headingDeg * .pi / 180
        let cosT = cos(theta)
        let sinT = sin(theta)

        // Un-rotated (heading 0): forward (-y) is north, +x is east. Rotating
        // the local frame clockwise by headingDeg rotates a fixed local vector
        // by the same angle when expressed in world east/north.
        let east = x * cosT - y * sinT
        let north = -x * sinT - y * cosT

        let lat = anchor.latitude + north / metersPerDegreeLat
        let lng = anchor.longitude + east / (metersPerDegreeLat * cos(lat * .pi / 180))

        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// Convenience for a node's `x`/`z` pair, applying the anchor's scale.
    static func coordinate(x: Double, z: Double, scaledBy anchor: BuildingAnchor) -> CLLocationCoordinate2D {
        coordinate(x: x * anchor.scale, y: z * anchor.scale, anchor: anchor)
    }
}
