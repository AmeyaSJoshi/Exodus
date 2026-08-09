"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import * as maplibregl from "maplibre-gl";
import type { Map as MLMap } from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import { buffer } from "@turf/buffer";
import { convex } from "@turf/convex";
import { featureCollection, lineString, point, polygon as turfPolygon } from "@turf/helpers";
import { supabase, type Building, type GeoJSONPolygon, type RouteEdge, type RouteNode } from "@/lib/supabase";
import { localToLatLng } from "@/lib/geo";

const STYLE_URL = "https://tiles.openfreemap.org/styles/liberty";
const FLOOR_HEIGHT_M = 3;
const SLAB_THICKNESS_M = 0.15;
const ROOM_HALF_WIDTH_M = 1.2;
const ROUTE_BUFFER_M = 0.35;
const BOUNDS_HALF_M = 200;
const GHOST_OPACITY = 0.1;

type LngLat = [number, number];
type Shell = { geojson: GeoJSONPolygon; height: number; source: "osm" | "hull" };

export function BuildingFocusView({
  building,
  nodes,
  edges,
  allFloors,
  canEdit,
  onFootprintCached,
}: {
  building: Building;
  nodes: RouteNode[];
  edges: RouteEdge[];
  allFloors: string[];
  canEdit: boolean;
  onFootprintCached?: (patch: Partial<Building>) => void;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<MLMap | null>(null);
  const [activeFloor, setActiveFloor] = useState<string>("all");
  const [shell, setShell] = useState<Shell | null>(
    building.footprint_geojson
      ? {
          geojson: building.footprint_geojson,
          height: building.footprint_height_m ?? allFloors.length * FLOOR_HEIGHT_M,
          source: "osm",
        }
      : null,
  );

  const anchorLat = building.anchor_lat;
  const anchorLng = building.anchor_lng;
  const hasAnchor = anchorLat != null && anchorLng != null;
  const heading = building.heading_deg ?? 0;
  const scale = building.scale || 1;

  const toLngLat = useCallback(
    (x: number, z: number): LngLat => {
      if (anchorLat == null || anchorLng == null) return [0, 0];
      const { lat, lng } = localToLatLng(x * scale, z * scale, { anchor_lat: anchorLat, anchor_lng: anchorLng }, heading);
      return [lng, lat];
    },
    [anchorLat, anchorLng, heading, scale],
  );

  const floorIndex = useCallback(
    (floorId: string) => {
      const i = allFloors.indexOf(floorId);
      return i < 0 ? 0 : i;
    },
    [allFloors],
  );

  /**
   * Everything the map draws, in one idempotent pass.
   *
   * Safe to call at any time and any number of times: the base style is muted
   * in place with setPaintProperty (never setStyle, which would destroy every
   * custom layer added here), and each source is updated via setData when it
   * already exists rather than re-added.
   */
  const applyOverlays = useCallback(
    (map: MLMap) => {
      // MARK: Mute the base style in place.
      for (const layer of map.getStyle().layers ?? []) {
        const id = layer.id;
        try {
          if (layer.type === "background") {
            map.setPaintProperty(id, "background-color", "#0d0e11");
          } else if (layer.type === "fill") {
            map.setPaintProperty(id, "fill-color", "#191c22");
            map.setPaintProperty(id, "fill-opacity", 0.6);
          } else if (layer.type === "line") {
            map.setPaintProperty(id, "line-color", "#2a2f38");
            map.setPaintProperty(id, "line-opacity", 0.5);
          } else if (layer.type === "symbol") {
            map.setPaintProperty(id, "text-color", "#5b6472");
            map.setPaintProperty(id, "text-halo-color", "#0d0e11");
          } else if (layer.type === "fill-extrusion") {
            map.setPaintProperty(id, "fill-extrusion-color", "#1c2028");
            map.setPaintProperty(id, "fill-extrusion-opacity", 0.4);
          }
        } catch {
          // Layer does not support that paint property — leave it as styled.
        }
      }

      const activeIdx = activeFloor === "all" ? -1 : floorIndex(activeFloor);
      const opacityExpr = (full: number): maplibregl.ExpressionSpecification | number =>
        activeIdx < 0 ? full : ["case", ["==", ["get", "floorIdx"], activeIdx], full, GHOST_OPACITY];

      // MARK: Building shell.
      if (shell) {
        const shellData = { type: "Feature" as const, properties: {}, geometry: shell.geojson };
        const existing = map.getSource("shell");
        if (existing) {
          (existing as maplibregl.GeoJSONSource).setData(shellData);
          map.setPaintProperty("shell", "fill-extrusion-height", shell.height);
        } else {
          map.addSource("shell", { type: "geojson", data: shellData });
          map.addLayer({
            id: "shell",
            type: "fill-extrusion",
            source: "shell",
            paint: {
              "fill-extrusion-color": "#7dd3fc",
              "fill-extrusion-height": shell.height,
              "fill-extrusion-base": 0,
              "fill-extrusion-opacity": 0.15,
            },
          });
          map.addLayer({
            id: "shell-outline",
            type: "line",
            source: "shell",
            paint: { "line-color": "#7dd3fc", "line-width": 2, "line-opacity": 0.9 },
          });
        }
      }

      // MARK: Floor slabs — convex hull of each floor's nodes, thin extrusion.
      const slabs = allFloors
        .map((fid) => {
          const onFloor = nodes.filter((n) => n.floor_id === fid);
          if (onFloor.length < 3) return null;
          const hull = convex(featureCollection(onFloor.map((n) => point(toLngLat(n.position.x, n.position.z)))));
          if (!hull) return null;
          const base = floorIndex(fid) * FLOOR_HEIGHT_M;
          return { ...hull, properties: { floorIdx: floorIndex(fid), base, top: base + SLAB_THICKNESS_M } };
        })
        .filter((f): f is NonNullable<typeof f> => f !== null);

      upsert(map, "slabs", featureCollection(slabs), {
        id: "slabs",
        type: "fill-extrusion",
        source: "slabs",
        paint: {
          "fill-extrusion-color": "#94a3b8",
          "fill-extrusion-height": ["get", "top"],
          "fill-extrusion-base": ["get", "base"],
          "fill-extrusion-opacity": opacityExpr(0.35),
        },
      });
      if (map.getLayer("slabs")) map.setPaintProperty("slabs", "fill-extrusion-opacity", opacityExpr(0.35));

      // MARK: Rooms — synthetic square footprints (the schema stores points).
      const rooms = nodes
        .filter((n) => n.type === "room")
        .map((n) => {
          const base = floorIndex(n.floor_id) * FLOOR_HEIGHT_M;
          const c: [number, number][] = [
            [n.position.x - ROOM_HALF_WIDTH_M, n.position.z - ROOM_HALF_WIDTH_M],
            [n.position.x + ROOM_HALF_WIDTH_M, n.position.z - ROOM_HALF_WIDTH_M],
            [n.position.x + ROOM_HALF_WIDTH_M, n.position.z + ROOM_HALF_WIDTH_M],
            [n.position.x - ROOM_HALF_WIDTH_M, n.position.z + ROOM_HALF_WIDTH_M],
          ];
          const r = c.map(([x, z]) => toLngLat(x, z));
          r.push(r[0]);
          return turfPolygon([r], { floorIdx: floorIndex(n.floor_id), base, top: base + FLOOR_HEIGHT_M });
        });

      upsert(map, "rooms", featureCollection(rooms), {
        id: "rooms",
        type: "fill-extrusion",
        source: "rooms",
        paint: {
          "fill-extrusion-color": "#3f8cff",
          "fill-extrusion-height": ["get", "top"],
          "fill-extrusion-base": ["get", "base"],
          "fill-extrusion-opacity": opacityExpr(0.55),
        },
      });
      if (map.getLayer("rooms")) map.setPaintProperty("rooms", "fill-extrusion-opacity", opacityExpr(0.55));

      // MARK: Escape routes. Line layers have no altitude, so each segment is
      // buffered into a polygon and extruded as a ribbon at floor height.
      const ribbons = edges
        .map((e) => {
          const a = nodes.find((n) => n.stable_id === e.from_node_stable_id);
          const b = nodes.find((n) => n.stable_id === e.to_node_stable_id);
          if (!a || !b) return null;
          const line = lineString([toLngLat(a.position.x, a.position.z), toLngLat(b.position.x, b.position.z)]);
          const ribbon = buffer(line, ROUTE_BUFFER_M, { units: "meters" });
          if (!ribbon) return null;
          const base = floorIndex(a.floor_id) * FLOOR_HEIGHT_M;
          return {
            ...ribbon,
            properties: {
              floorIdx: floorIndex(a.floor_id),
              base: base + 0.1,
              top: base + 0.4,
              stepFree: e.wheelchair_accessible && !e.contains_stairs,
            },
          };
        })
        .filter((f): f is NonNullable<typeof f> => f !== null);

      upsert(map, "routes", featureCollection(ribbons), {
        id: "routes",
        type: "fill-extrusion",
        source: "routes",
        paint: {
          "fill-extrusion-color": ["case", ["get", "stepFree"], "#22c55e", "#ef4444"],
          "fill-extrusion-height": ["get", "top"],
          "fill-extrusion-base": ["get", "base"],
          "fill-extrusion-opacity": opacityExpr(0.95),
        },
      });
      if (map.getLayer("routes")) map.setPaintProperty("routes", "fill-extrusion-opacity", opacityExpr(0.95));

      // MARK: Exits and waypoints.
      const labels = nodes
        .filter((n) => n.type !== "hallwayPoint")
        .map((n) =>
          point(toLngLat(n.position.x, n.position.z), {
            floorIdx: floorIndex(n.floor_id),
            name: n.name,
            isExit: n.type === "exit",
          }),
        );

      upsert(map, "labels", featureCollection(labels), {
        id: "labels",
        type: "symbol",
        source: "labels",
        layout: {
          "text-field": ["case", ["get", "isExit"], ["concat", "▲ ", ["get", "name"]], ["get", "name"]],
          "text-size": ["case", ["get", "isExit"], 13, 11],
          "text-offset": [0, -0.8],
          "text-allow-overlap": false,
        },
        paint: {
          "text-color": ["case", ["get", "isExit"], "#22c55e", "#e6e8ec"],
          "text-halo-color": "#0d0e11",
          "text-halo-width": 1.5,
          "text-opacity": opacityExpr(1),
        },
      });
      if (map.getLayer("labels")) map.setPaintProperty("labels", "text-opacity", opacityExpr(1));

      // eslint-disable-next-line no-console
      console.log(
        `[focus] styleLoaded=${map.isStyleLoaded()} layers=${(map.getStyle().layers ?? []).length} shell=${shell?.source ?? "none"}`,
      );
    },
    [shell, nodes, edges, allFloors, activeFloor, toLngLat, floorIndex],
  );

  // MARK: Map creation — exactly once, StrictMode-safe.
  useEffect(() => {
    if (mapRef.current || !containerRef.current || anchorLat == null || anchorLng == null) return;

    const sw = localToLatLng(-BOUNDS_HALF_M, BOUNDS_HALF_M, { anchor_lat: anchorLat, anchor_lng: anchorLng }, 0);
    const ne = localToLatLng(BOUNDS_HALF_M, -BOUNDS_HALF_M, { anchor_lat: anchorLat, anchor_lng: anchorLng }, 0);

    const map = new maplibregl.Map({
      container: containerRef.current,
      style: STYLE_URL,
      center: [anchorLng, anchorLat],
      zoom: 18.5,
      pitch: 60,
      maxPitch: 85,
      minZoom: 16,
      maxBounds: [
        [sw.lng, sw.lat],
        [ne.lng, ne.lat],
      ],
      attributionControl: { compact: true },
    });
    mapRef.current = map;
    map.dragRotate.enable();
    map.addControl(new maplibregl.NavigationControl({ visualizePitch: true }), "bottom-right");

    map.once("load", () => map.resize());

    // The container is laid out by a responsive grid, so its size can settle
    // after the map is constructed.
    const ro = new ResizeObserver(() => map.resize());
    ro.observe(containerRef.current);

    return () => {
      ro.disconnect();
      mapRef.current?.remove();
      mapRef.current = null;
    };
  }, [anchorLat, anchorLng]);

  // MARK: Overlays — re-applied whenever the data or the active floor changes.
  // Two-sided guard: the style may already be loaded by the time this runs
  // (async footprint resolving late), or may not be (first mount).
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    // `load` fires exactly once and is easy to miss (a late-resolving footprint
    // re-runs this effect long after it fired). `styledata` fires whenever the
    // style is (re)parsed and keeps firing, so combined with an isStyleLoaded
    // check it is safe both before and after the style is ready.
    const run = () => {
      if (!map.isStyleLoaded()) return;
      applyOverlays(map);
    };
    run();
    map.on("styledata", run);
    // `idle` fires once the style is loaded AND all pending tiles are rendered.
    // styledata alone can pass its isStyleLoaded check at a moment when paint
    // operations are still dropped, so this is the one that reliably sticks.
    map.on("idle", run);
    return () => {
      map.off("styledata", run);
      map.off("idle", run);
    };
  }, [applyOverlays]);

  // MARK: Footprint — cached column first, then Overpass, then our own hull.
  useEffect(() => {
    if (anchorLat == null || anchorLng == null || shell) return;
    let cancelled = false;
    void (async () => {
      try {
        const res = await fetch("/api/building-footprint", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ lat: anchorLat, lng: anchorLng, floorCount: allFloors.length }),
        });
        if (cancelled) return;
        if (res.ok) {
          const data = await res.json();
          setShell({ geojson: data.geojson, height: data.height_m, source: "osm" });
          if (canEdit) {
            const patch = { footprint_geojson: data.geojson, footprint_height_m: data.height_m };
            await supabase.from("buildings").update(patch).eq("id", building.id);
            if (!cancelled) onFootprintCached?.(patch);
          }
          return;
        }
      } catch {
        // fall through to the hull fallback
      }
      if (cancelled || !nodes.length) return;
      const hull = convex(featureCollection(nodes.map((n) => point(toLngLat(n.position.x, n.position.z)))));
      if (!hull) return;
      const padded = buffer(hull, 2, { units: "meters" });
      if (padded && !cancelled) {
        setShell({
          geojson: padded.geometry as GeoJSONPolygon,
          height: Math.max(1, allFloors.length) * FLOOR_HEIGHT_M,
          source: "hull",
        });
      }
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [anchorLat, anchorLng, building.id, allFloors.length, nodes.length, canEdit, shell]);

  if (!hasAnchor) {
    return (
      <div className="flex h-[520px] items-center justify-center rounded-xl border border-hairline bg-surface p-8 text-center">
        <p className="max-w-sm text-sm text-ink-2">
          This building has no location set. Use the Location panel to set one before using the focus view.
        </p>
      </div>
    );
  }

  return (
    <div className="relative overflow-hidden rounded-xl border border-hairline bg-surface">
      <div className="absolute left-3 top-3 z-10 flex flex-wrap gap-1.5">
        <button
          type="button"
          aria-pressed={activeFloor === "all"}
          onClick={() => setActiveFloor("all")}
          className={`rounded-md border border-hairline px-2.5 py-1.5 text-xs font-medium ${
            activeFloor === "all" ? "bg-critical text-white" : "bg-surface/95 text-ink-2"
          }`}
        >
          All floors
        </button>
        {allFloors.map((f) => (
          <button
            key={f}
            type="button"
            aria-pressed={activeFloor === f}
            onClick={() => setActiveFloor(f)}
            className={`rounded-md border border-hairline px-2.5 py-1.5 text-xs font-medium ${
              activeFloor === f ? "bg-critical text-white" : "bg-surface/95 text-ink-2"
            }`}
          >
            {f}
          </button>
        ))}
      </div>

      {shell?.source === "hull" && (
        <div className="absolute right-3 top-3 z-10 rounded-md border border-hairline bg-surface/95 px-2.5 py-1.5 text-xs text-ink-2">
          No OSM footprint — shell derived from mapped points.
        </div>
      )}

      <div ref={containerRef} className="h-[520px] w-full" />
    </div>
  );
}

/** Add the source+layer on first call, update the data on every call after. */
function upsert(
  map: MLMap,
  id: string,
  data: GeoJSON.FeatureCollection,
  layer: maplibregl.LayerSpecification,
) {
  const existing = map.getSource(id);
  if (existing) {
    (existing as maplibregl.GeoJSONSource).setData(data);
    return;
  }
  map.addSource(id, { type: "geojson", data });
  map.addLayer(layer);
}
