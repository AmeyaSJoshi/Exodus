/**
 * Local AR meters -> real-world lat/lng, using a building's georeference
 * anchor (see the `anchor_lat`/`anchor_lng`/`heading_deg` columns added in
 * 20260806000900_building_georeference.sql).
 *
 * `RouteNode.position` is `{x, y, z}` in ARKit world space: X is right, Y is
 * up (capture height — irrelevant here, handled separately as floor
 * altitude), Z is *toward* the camera, so -Z is "forward" from wherever the
 * mapper was facing when the AR session started (see GraphView in graph.tsx,
 * which already plots x/z as the top-down plane and ignores y for the same
 * reason).
 *
 * ARKit does not know compass heading unless the session opts into
 * `.gravityAndHeading` world alignment, which this app's ARSessionManager
 * does not — the initial "forward" is arbitrary. `heading_deg` is exactly
 * that missing piece: the compass bearing (clockwise from true north) that
 * local "forward" (-Z) pointed to in the real world when the anchor was set.
 * At heading 0, forward = north and right = east, which is why GraphView's
 * unrotated x/z plot already reads as a normal north-up floor plan.
 */

export type LatLngAnchor = {
  anchor_lat: number;
  anchor_lng: number;
};

/** Meters per degree of latitude. Treated as constant — accurate to within
 * centimeters over the tens-to-hundreds-of-meters span of a single building. */
const METERS_PER_DEGREE_LAT = 111_320;

/**
 * @param x_m Local AR meters along the building's local +X (right) axis.
 * @param y_m Local AR meters along the building's local *planar* depth axis —
 *   callers pass `node.position.z`, never `node.position.y` (AR height).
 *   Named `y_m` because this is a generic 2D local-to-geo transform; the
 *   z-vs-height distinction lives at the call site, not in this function.
 * @param anchor The building's real-world anchor point.
 * @param heading_deg Compass bearing of local forward (-Z / -y_m), clockwise
 *   from true north, in degrees.
 */
export function localToLatLng(
  x_m: number,
  y_m: number,
  anchor: LatLngAnchor,
  heading_deg: number,
): { lat: number; lng: number } {
  const theta = (heading_deg * Math.PI) / 180;
  const cos = Math.cos(theta);
  const sin = Math.sin(theta);

  // Un-rotated (heading 0): forward (-y_m) is north, +x_m is east. Rotating
  // the local frame clockwise by heading_deg rotates a fixed local vector by
  // the same angle when expressed in world east/north.
  const east = x_m * cos - y_m * sin;
  const north = -x_m * sin - y_m * cos;

  const lat = anchor.anchor_lat + north / METERS_PER_DEGREE_LAT;
  const lng = anchor.anchor_lng + east / (METERS_PER_DEGREE_LAT * Math.cos((lat * Math.PI) / 180));

  return { lat, lng };
}
