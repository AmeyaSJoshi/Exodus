"use client";
import { createClient } from "@supabase/supabase-js";
import type { EdgeStatus } from "./model";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
// `PUBLISHABLE_KEY` is Supabase's current name for the anon key. Either is
// accepted so a project created before or after the rename works unchanged.
const anonKey =
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

if (!url || !anonKey) {
  throw new Error(
    "Missing NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY. " +
      "Copy dashboard/.env.example to dashboard/.env.local and fill it in.",
  );
}

// Publishable/anon key only. The service-role key must never reach the browser.
export const supabase = createClient(url, anonKey, {
  realtime: { params: { eventsPerSecond: 10 } },
});

export type Building = {
  id: string;
  name: string;
  address: string | null;
  active_map_version_id: string | null;
  anchor_lat: number | null;
  anchor_lng: number | null;
  anchor_alt_m: number;
  heading_deg: number;
  scale: number;
  formatted_address: string | null;
  footprint_geojson: GeoJSONPolygon | null;
  footprint_height_m: number | null;
};

export type GeoJSONPolygon = {
  type: "Polygon";
  coordinates: number[][][];
};

export type MapVersion = { id: string; version: number; status: string; published_at: string | null };

export type Profile = { id: string; role: string; display_name: string | null; organization_id: string };

export type RouteNode = {
  id: string;
  stable_id: string;
  floor_id: string;
  name: string;
  type: string;
  position: { x: number; y: number; z: number };
};

export type RouteEdge = {
  id: string;
  stable_id: string;
  from_node_stable_id: string;
  to_node_stable_id: string;
  distance_meters: number;
  contains_stairs: boolean;
  requires_elevator: boolean;
  wheelchair_accessible: boolean;
};

export type LiveEdgeState = {
  edge_stable_id: string;
  status: EdgeStatus;
  hazard_type: string | null;
  reason: string | null;
  severity: number;
  revision: number;
  expires_at: string | null;
  updated_at?: string | null;
};

export type UserReport = {
  id: string;
  building_id: string;
  edge_stable_id: string | null;
  node_stable_id: string | null;
  reporter_id: string | null;
  report_type: string;
  description: string | null;
  status: "pending" | "verified" | "rejected";
  created_at: string;
  reviewed_at: string | null;
};

export type AuditEntry = {
  id: string;
  target_kind: "edge" | "node";
  target_id: string;
  new_state: { status?: string; hazard_type?: string | null; reason?: string | null } | null;
  previous_state: { status?: string } | null;
  revision: number | null;
  created_at: string;
};
