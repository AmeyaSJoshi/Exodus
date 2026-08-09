import { NextResponse } from "next/server";
import booleanPointInPolygon from "@turf/boolean-point-in-polygon";
import type { GeoJSONPolygon } from "@/lib/supabase";

// Server-side Overpass lookup for the OSM building at a given anchor point.
// Proxied rather than called from the browser so the dashboard is not making
// cross-origin requests to a shared community endpoint from every client tab.

const OVERPASS_URL = "https://overpass-api.de/api/interpreter";
const SEARCH_RADIUS_M = 40;
const DEFAULT_LEVEL_HEIGHT_M = 3;

type OverpassNode = { lat: number; lon: number };
type OverpassElement = {
  type: "way" | "relation";
  tags?: Record<string, string>;
  geometry?: OverpassNode[];
  members?: { role?: string; geometry?: OverpassNode[] }[];
};

function ring(geometry: OverpassNode[]): number[][] {
  const coords = geometry.map((p) => [p.lon, p.lat]);
  const first = coords[0];
  const last = coords[coords.length - 1];
  if (first && last && (first[0] !== last[0] || first[1] !== last[1])) coords.push([...first]);
  return coords;
}

function toPolygon(el: OverpassElement): GeoJSONPolygon | null {
  if (el.geometry && el.geometry.length >= 3) {
    return { type: "Polygon", coordinates: [ring(el.geometry)] };
  }
  const outer = el.members?.find((m) => m.role === "outer" && m.geometry && m.geometry.length >= 3);
  if (outer?.geometry) return { type: "Polygon", coordinates: [ring(outer.geometry)] };
  return null;
}

/** OSM `height` is metres but may carry a unit suffix ("12", "12 m"). */
function parseHeight(tags: Record<string, string> | undefined, floorCount: number): number {
  const raw = tags?.height ? Number.parseFloat(tags.height) : NaN;
  if (Number.isFinite(raw) && raw > 0) return raw;
  const levels = tags?.["building:levels"] ? Number.parseFloat(tags["building:levels"]) : NaN;
  if (Number.isFinite(levels) && levels > 0) return levels * DEFAULT_LEVEL_HEIGHT_M;
  return Math.max(1, floorCount) * DEFAULT_LEVEL_HEIGHT_M;
}

function centroid(p: GeoJSONPolygon): [number, number] {
  const r = p.coordinates[0];
  const sum = r.reduce((acc, c) => [acc[0] + c[0], acc[1] + c[1]], [0, 0]);
  return [sum[0] / r.length, sum[1] / r.length];
}

export async function POST(request: Request) {
  let lat: unknown, lng: unknown, floorCount: unknown;
  try {
    ({ lat, lng, floorCount } = await request.json());
  } catch {
    return NextResponse.json({ error: "Request body must be JSON." }, { status: 400 });
  }
  if (typeof lat !== "number" || typeof lng !== "number") {
    return NextResponse.json({ error: "lat and lng are required numbers." }, { status: 400 });
  }
  const floors = typeof floorCount === "number" && floorCount > 0 ? floorCount : 1;

  const query = `[out:json][timeout:25];(way["building"](around:${SEARCH_RADIUS_M},${lat},${lng});relation["building"](around:${SEARCH_RADIUS_M},${lat},${lng}););out geom;`;

  let data: { elements?: OverpassElement[] };
  try {
    const upstream = await fetch(OVERPASS_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        // Overpass rejects requests without a descriptive User-Agent (406).
        "User-Agent": "EGRESS/1.0 (dev)",
      },
      body: `data=${encodeURIComponent(query)}`,
    });
    if (!upstream.ok) {
      return NextResponse.json({ error: `Overpass returned ${upstream.status}.` }, { status: 502 });
    }
    data = await upstream.json();
  } catch {
    return NextResponse.json({ error: "Could not reach Overpass." }, { status: 502 });
  }

  const candidates = (data.elements ?? [])
    .map((el) => ({ el, polygon: toPolygon(el) }))
    .filter((c): c is { el: OverpassElement; polygon: GeoJSONPolygon } => c.polygon !== null);

  if (!candidates.length) {
    return NextResponse.json({ error: "No OSM building found near this anchor." }, { status: 404 });
  }

  // Prefer the polygon actually containing the anchor; otherwise the nearest.
  const containing = candidates.find((c) => booleanPointInPolygon([lng, lat], c.polygon));
  const chosen =
    containing ??
    candidates.reduce((best, c) => {
      const d = (p: GeoJSONPolygon) => {
        const [cx, cy] = centroid(p);
        return (cx - lng) ** 2 + (cy - lat) ** 2;
      };
      return d(c.polygon) < d(best.polygon) ? c : best;
    });

  return NextResponse.json({
    geojson: chosen.polygon,
    height_m: parseHeight(chosen.el.tags, floors),
    contained: Boolean(containing),
  });
}
