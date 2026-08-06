# Live Building State — Plan

Date: 2026-08-06
Status: Milestone 1 (backend) in progress

## Baseline

- iOS app `EgressMapper/` — 171 tests passing; simulator and signed device builds clean.
- Existing models reused as-is: `RouteNode`, `RouteEdge`, `EdgeAccessibility`,
  `RouteHazard`, `BuildingGraph` (versioned), `ActiveHazards`, `NavigationProfile`,
  `RoutePosition`, `MappingZone`.
- Existing routing (`ShortestPathService`) already excludes blocked and
  profile-violating edges. **Live state needs no new routing logic** — it only has
  to produce a graph with the right edges marked blocked.

## Structure (added, nothing moved)

```
EgressMapper/   existing iOS app (unchanged in M1)
dashboard/      Next.js admin dashboard (M3)
supabase/
  migrations/
  seed.sql
  tests/
docs/
```

## Two schema decisions that deviate from the brief

**1. `stable_id` separates "which row" from "which thing".**
The brief specifies `route_nodes.id uuid pk` *and* "preserve existing UUIDs".
Those conflict the moment map v2 is published: the same iOS node UUID would need
to exist in two versions, violating the primary key.

Resolution: `id` is a per-version row id; **`stable_id` carries the iOS UUID** and
is unique *within* a version. Edges reference nodes by `(map_version_id, stable_id)`
via a composite foreign key, so referential integrity still holds.

**2. Live state references `stable_id`, not a versioned row.**
A blocked stairwell must survive a map republish. `live_edge_states.edge_stable_id`
therefore points at the durable identity, not at a row that a new version replaces.
A trigger validates the id exists in the building's active published version.

## Revisions

A single global `BIGSERIAL` sequence assigns `revision` via trigger on every insert
and update of `live_edge_states` / `live_node_states`. Global (not per-building)
monotonicity means a client can hold one integer watermark and discard any event
at or below it, regardless of ordering or duplicate delivery.

## Security model

`profiles` maps `auth.users` → `organization_id` + `role`. Two `SECURITY DEFINER`
helpers (`current_org_id()`, `is_admin()`) read it without triggering recursive RLS.

- Occupants: read published maps + live state for their org; insert their own reports.
- Occupants **cannot** write `live_edge_states` / `live_node_states` — no policy grants it.
- Admins: full live-state control and map publishing, scoped to their own org.
- Cross-organization access is impossible: every policy filters on `current_org_id()`.
- Service-role key stays server-side only; `.env.example` documents the split.

## Layering (M4/M5, already supported by existing code)

```
PermanentGraph (graph.json)
  + LiveStateOverlay (server)
  + PersonalOverlay (this user's unverified report)
  = EffectiveGraph  ->  existing ShortestPathService
```

`BuildingGraph.applying(hazards:)` already produces a copy without mutating the
stored graph, and is already covered by tests. Live state reuses that path.

## Milestones

1. **Backend** — migrations, RLS, roles, seed, security verification queries. *(this one)*
2. **Map sync** — publish graph from iOS, download + cache, versioning, tests.
3. **Dashboard** — login, graph view, status editor, pending reports.
4. **iPhone realtime** — snapshot, subscription, revisions, offline cache, effective graph.
5. **Live rerouting** — arrow teardown, local recalculation, accessibility, voice/haptics,
   two-device verification.

## Out of scope

Crowd simulation, external AI APIs, service-role keys on any client, multi-floor
routing, CAD-style map editing.
