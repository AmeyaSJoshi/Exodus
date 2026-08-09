import CoreLocation
import XCTest
@testable import EgressMapper

/// Ported one-for-one from `dashboard/lib/geo.test.ts` — same inputs, same
/// expected values. The dashboard and the phone must place a node in the same
/// spot, so the two suites are kept literally in sync rather than paraphrased.
final class LocalGeoTests: XCTestCase {
    private let equator = BuildingAnchor(
        latitude: 0, longitude: 0, altitudeM: 0, headingDeg: 0, scale: 1
    )
    /// Wade Academic Center, from seed.sql and the security checks.
    private func wade(heading: Double = 0) -> BuildingAnchor {
        BuildingAnchor(latitude: 37.422, longitude: -122.084, altitudeM: 0, headingDeg: heading, scale: 1)
    }

    private func anchor(_ base: BuildingAnchor, heading: Double) -> BuildingAnchor {
        var a = base
        a.headingDeg = heading
        return a
    }

    func test100mNorthIsPlus0000898Lat() {
        // Forward (-y) is north at heading 0, so 100m north is y = -100.
        let c = LocalGeo.coordinate(x: 0, y: -100, anchor: equator)
        XCTAssertEqual(c.latitude, 0.000898, accuracy: 1e-6)
        XCTAssertEqual(c.longitude, 0, accuracy: 1e-9)
    }

    func test100mSouthIsMinus0000898Lat() {
        let c = LocalGeo.coordinate(x: 0, y: 100, anchor: equator)
        XCTAssertEqual(c.latitude, -0.000898, accuracy: 1e-6)
        XCTAssertEqual(c.longitude, 0, accuracy: 1e-9)
    }

    func test100mEastIsPlus0000898LngAtEquator() {
        let c = LocalGeo.coordinate(x: 100, y: 0, anchor: equator)
        XCTAssertEqual(c.latitude, 0, accuracy: 1e-9)
        XCTAssertEqual(c.longitude, 0.000898, accuracy: 1e-6)
    }

    func test100mWestIsMinus0000898Lng() {
        let c = LocalGeo.coordinate(x: -100, y: 0, anchor: equator)
        XCTAssertEqual(c.longitude, -0.000898, accuracy: 1e-6)
    }

    func testAnchorItselfMapsToItsOwnCoordinate() {
        let a = wade(heading: 47)
        let c = LocalGeo.coordinate(x: 0, y: 0, anchor: a)
        XCTAssertEqual(c.latitude, a.latitude, accuracy: 1e-9)
        XCTAssertEqual(c.longitude, a.longitude, accuracy: 1e-9)
    }

    func testHeading90RotatesForwardToEast() {
        // At heading 90, "forward" (-y) now points east instead of north.
        let c = LocalGeo.coordinate(x: 0, y: -100, anchor: anchor(equator, heading: 90))
        XCTAssertEqual(c.latitude, 0, accuracy: 1e-6)
        XCTAssertEqual(c.longitude, 0.000898, accuracy: 1e-6)
    }

    func testHeading180FlipsForwardToSouth() {
        let c = LocalGeo.coordinate(x: 0, y: -100, anchor: anchor(equator, heading: 180))
        XCTAssertEqual(c.latitude, -0.000898, accuracy: 1e-6)
        XCTAssertEqual(c.longitude, 0, accuracy: 1e-6)
    }

    func testLongitudeDegreesShrinkTowardThePoles() {
        // The same 100m east is a larger longitude delta at Wade's latitude
        // than at the equator.
        let atEquator = LocalGeo.coordinate(x: 100, y: 0, anchor: equator)
        let w = wade()
        let atWade = LocalGeo.coordinate(x: 100, y: 0, anchor: w)
        XCTAssertGreaterThan(atWade.longitude - w.longitude, atEquator.longitude - equator.longitude)
    }

    /// Not in the TypeScript suite: the Swift wrapper additionally folds in the
    /// anchor's `scale`, so that multiplication is covered here.
    func testScaleMultipliesLocalMetres() {
        var a = equator
        a.scale = 2
        let c = LocalGeo.coordinate(x: 0, z: -50, scaledBy: a)
        XCTAssertEqual(c.latitude, 0.000898, accuracy: 1e-6)
    }
}
