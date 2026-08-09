import { describe, expect, it } from "vitest";
import { localToLatLng } from "./geo";

const EQUATOR_ORIGIN = { anchor_lat: 0, anchor_lng: 0 };
// Wade Academic Center from seed.sql / the security checks.
const WADE = { anchor_lat: 37.422, anchor_lng: -122.084 };

describe("localToLatLng", () => {
  it("100m north (heading 0) is +0.000898 lat, no lng change", () => {
    // Forward (-y_m) is north at heading 0, so 100m north is y_m = -100.
    const { lat, lng } = localToLatLng(0, -100, EQUATOR_ORIGIN, 0);
    expect(lat).toBeCloseTo(0.000898, 6);
    expect(lng).toBeCloseTo(0, 9);
  });

  it("100m south (heading 0) is -0.000898 lat", () => {
    const { lat, lng } = localToLatLng(0, 100, EQUATOR_ORIGIN, 0);
    expect(lat).toBeCloseTo(-0.000898, 6);
    expect(lng).toBeCloseTo(0, 9);
  });

  it("100m east (heading 0) is +0.000898 lng at the equator, no lat change", () => {
    const { lat, lng } = localToLatLng(100, 0, EQUATOR_ORIGIN, 0);
    expect(lat).toBeCloseTo(0, 9);
    expect(lng).toBeCloseTo(0.000898, 6);
  });

  it("100m west (heading 0) is -0.000898 lng", () => {
    const { lat, lng } = localToLatLng(-100, 0, EQUATOR_ORIGIN, 0);
    expect(lng).toBeCloseTo(-0.000898, 6);
  });

  it("the anchor itself maps to the anchor's own lat/lng", () => {
    const { lat, lng } = localToLatLng(0, 0, WADE, 47);
    expect(lat).toBeCloseTo(WADE.anchor_lat, 9);
    expect(lng).toBeCloseTo(WADE.anchor_lng, 9);
  });

  it("heading 90 rotates local forward to point east", () => {
    // At heading 90, "forward" (-y_m) now points east instead of north.
    const { lat, lng } = localToLatLng(0, -100, EQUATOR_ORIGIN, 90);
    expect(lat).toBeCloseTo(0, 6);
    expect(lng).toBeCloseTo(0.000898, 6);
  });

  it("heading 180 flips forward to point south", () => {
    const { lat, lng } = localToLatLng(0, -100, EQUATOR_ORIGIN, 180);
    expect(lat).toBeCloseTo(-0.000898, 6);
    expect(lng).toBeCloseTo(0, 6);
  });

  it("longitude degrees shrink toward the poles: same 100m east is a bigger lng delta at Wade's latitude than at the equator", () => {
    const atEquator = localToLatLng(100, 0, EQUATOR_ORIGIN, 0);
    const atWade = localToLatLng(100, 0, WADE, 0);
    const equatorDelta = atEquator.lng - EQUATOR_ORIGIN.anchor_lng;
    const wadeDelta = atWade.lng - WADE.anchor_lng;
    expect(wadeDelta).toBeGreaterThan(equatorDelta);
  });
});
