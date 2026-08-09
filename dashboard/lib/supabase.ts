"use client";
import { createClient } from "@supabase/supabase-js";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

if (!url || !anonKey) {
  throw new Error(
    "Missing NEXT_PUBLIC_SUPABASE_URL / NEXT_PUBLIC_SUPABASE_ANON_KEY. " +
      "Copy dashboard/.env.example to dashboard/.env.local and fill it from `npx supabase status`.",
  );
}

// Anon key only. The service-role key must never reach the browser.
export const supabase = createClient(url, anonKey, {
  realtime: { params: { eventsPerSecond: 10 } },
});

export type Building = { id: string; name: string; address: string | null; active_map_version_id: string | null };
export type RouteNode = {
  id: string; stable_id: string; floor_id: string; name: string; type: string;
  position: { x: number; y: number; z: number };
};
export type RouteEdge = {
  id: string; stable_id: string; from_node_stable_id: string; to_node_stable_id: string;
  distance_meters: number; contains_stairs: boolean; requires_elevator: boolean; wheelchair_accessible: boolean;
};
export type LiveEdgeState = {
  edge_stable_id: string; status: "available" | "blocked" | "restricted";
  hazard_type: string | null; reason: string | null; severity: number; revision: number;
};
