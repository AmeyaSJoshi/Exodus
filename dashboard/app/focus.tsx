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
  // Set once, on the style's first `styledata`. Deliberately not
  // isStyleLoaded(): that flickers false whenever any source is loading,
  // including the geojson sources this component adds, so polling it made
  // readiness nondeterministic.
  const styleReadyRef = useRef(false);
  // How many base-style (non-egress) layers were present at the last apply.
  // styledata can fire first on an interim style with no layers at all; the
  // mute pass then has nothing to paint. Re-applying whenever this count
  // changes converges on the real style without ever looping on our own
  // paint edits, which never change the layer count.
  const baseLayerCountRef = useRef(-1);
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
      // MARK: Mute the base style in place. Our own layers carry the `egress-`
      // prefix and are skipped: the mute pass runs again on every data change,
      // and without this it would darken the overlay into the background it is
      // meant to stand out from.
      for (const layer of map.getStyle().layers ?? []) {
        const id = layer.id;
        if (id.startsWith("egress-")) continue;
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
        } catch (err) {
          // eslint-disable-next-line no-console
          console.warn(`[focus] mute failed on layer "${id}"`, err);
        }
      }

      const activeIdx = activeFloor === "all" ? -1 : floorIndex(activeFloor);
      const opacityExpr = (full: number): maplibregl.ExpressionSpecification | number =>
        activeIdx < 0 ? full : ["case", ["==", ["get", "floorIdx"], activeIdx], full, GHOST_OPACITY];

      // MARK: Building shell.
      if (shell) {
        const shellData = { type: "Feature" as const, properties: {}, geometry: shell.geojson };
        const existing = map.getSource("egress-shell");
        if (existing) {
          (existing as maplibregl.GeoJSONSource).setData(shellData);
          map.setPaintProperty("egress-shell", "fill-extrusion-height", shell.height);
        } else {
          map.addSource("egress-shell", { type: "geojson", data: shellData });
          map.addLayer({
            id: "egress-shell",
            type: "fill-extrusion",
            source: "egress-shell",
            paint: {
              "fill-extrusion-color": "#38bdf8",
              "fill-extrusion-height": shell.height,
              "fill-extrusion-base": 0,
              "fill-extrusion-opacity": 0.25,
            },
          });
          map.addLayer({
            id: "egress-shell-outline",
            type: "line",
            source: "egress-shell",
            paint: { "line-color": "#7dd3fc", "line-width": 3, "line-opacity": 1 },
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

      upsert(map, "egress-slabs", featureCollection(slabs), {
        id: "egress-slabs",
        type: "fill-extrusion",
        source: "egress-slabs",
        paint: {
          "fill-extrusion-color": "#e2e8f0",
          "fill-extrusion-height": ["get", "top"],
          "fill-extrusion-base": ["get", "base"],
          "fill-extrusion-opacity": opacityExpr(0.6),
        },
      });
      if (map.getLayer("egress-slabs")) {
        map.setPaintProperty("egress-slabs", "fill-extrusion-opacity", opacityExpr(0.6));
      }

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

      upsert(map, "egress-rooms", featureCollection(rooms), {
        id: "egress-rooms",
        type: "fill-extrusion",
        source: "egress-rooms",
        paint: {
          "fill-extrusion-color": "#60a5fa",
          "fill-extrusion-height": ["get", "top"],
          "fill-extrusion-base": ["get", "base"],
          "fill-extrusion-opacity": opacityExpr(0.85),
        },
      });
      if (map.getLayer("egress-rooms")) {
        map.setPaintProperty("egress-rooms", "fill-extrusion-opacity", opacityExpr(0.85));
      }

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

      upsert(map, "egress-routes", featureCollection(ribbons), {
        id: "egress-routes",
        type: "fill-extrusion",
        source: "egress-routes",
        paint: {
          "fill-extrusion-color": ["case", ["get", "stepFree"], "#22ff88", "#ff4d4d"],
          "fill-extrusion-height": ["get", "top"],
          "fill-extrusion-base": ["get", "base"],
          "fill-extrusion-opacity": opacityExpr(1),
        },
      });
      if (map.getLayer("egress-routes")) {
        map.setPaintProperty("egress-routes", "fill-extrusion-opacity", opacityExpr(1));
      }

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

      upsert(map, "egress-labels", featureCollection(labels), {
        id: "egress-labels",
        type: "symbol",
        source: "egress-labels",
        layout: {
          // A font Liberty actually serves; the MapLibre default fontstack
          // 404s on OpenFreeMap's glyph endpoint and floods the console.
          "text-font": ["Noto Sans Regular"],
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
      if (map.getLayer("egress-labels")) {
        map.setPaintProperty("egress-labels", "text-opacity", opacityExpr(1));
      }

      const all = map.getStyle().layers ?? [];
      const ours = all.filter((l) => l.id.startsWith("egress-")).map((l) => l.id);
      baseLayerCountRef.current = all.length - ours.length;

      // Paint edits update the style but a frame is not always scheduled for
      // them (observed: muted values in the style, stale colours on screen
      // until the next tile arrival forced a render). One explicit frame
      // makes the apply visible immediately; the delayed second kick covers
      // applies that land while the tab's animation frames are throttled.
      map.triggerRepaint();
      setTimeout(() => map.triggerRepaint(), 300);
      // eslint-disable-next-line no-console
      console.log(
        `[focus] applied base=${baseLayerCountRef.current} ours=${ours.length} shell=${shell?.source ?? "none"}`,
      );
    },
    [shell, nodes, edges, allFloors, activeFloor, toLngLat, floorIndex],
  );

  // The creation effect must not depend on applyOverlays (that would tear the
  // map down on every data change), so it reaches the latest one through a ref.
  const applyOverlaysRef = useRef(applyOverlays);
  useEffect(() => {
    applyOverlaysRef.current = applyOverlays;
  }, [applyOverlays]);

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
    if (process.env.NODE_ENV === "development") {
      // Debug handle only; never referenced by application code.
      (window as unknown as Record<string, unknown>).__egressMap = map;
    }
    map.dragRotate.enable();
    map.addControl(new maplibregl.NavigationControl({ visualizePitch: true }), "bottom-right");

    // Attached synchronously at construction, so the event cannot be missed.
    // `styledata` rather than `load`: adding layers and setting paint only
    // needs the parsed style, while `load` additionally waits for every
    // initial tile — and a single stalled tile request postpones it
    // indefinitely (observed >2min in constrained environments), leaving the
    // overlay invisible on an otherwise fine map. The listener stays attached
    // because the first firing can precede the fetched style (an interim
    // style with zero layers); the base-layer-count guard makes re-applies
    // converge instead of looping.
    const onStyleData = () => {
      const baseCount = (map.getStyle().layers ?? []).filter((l) => !l.id.startsWith("egress-")).length;
      if (baseCount === baseLayerCountRef.current) return;
      map.resize();
      styleReadyRef.current = true;
      applyOverlaysRef.current(map);
    };
    map.on("styledata", onStyleData);

    // The container is laid out by a responsive grid, so its size can settle
    // after the map is constructed.
    const ro = new ResizeObserver(() => map.resize());
    ro.observe(containerRef.current);

    return () => {
      ro.disconnect();
      map.off("styledata", onStyleData);
      mapRef.current?.remove();
      mapRef.current = null;
      styleReadyRef.current = false;
      baseLayerCountRef.current = -1;
    };
  }, [anchorLat, anchorLng]);

  // MARK: Overlays — re-applied whenever the data or the active floor changes.
  // Two-sided guard: the style may already be loaded by the time this runs
  // (async footprint resolving late), or may not be (first mount).
  useEffect(() => {
    const map = mapRef.current;
    // Data that arrives after the style is ready is drawn immediately; data
    // that arrives before it is picked up by the `load` handler above, which
    // reads the latest applyOverlays through its ref. No polling either way.
    if (map && styleReadyRef.current) applyOverlays(map);
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
