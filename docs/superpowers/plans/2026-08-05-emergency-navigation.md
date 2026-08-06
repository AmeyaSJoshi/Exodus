# EGRESS — Emergency Navigation Implementation Plan

Date: 2026-08-05
Status: Milestones 1-5 implemented; all AR behaviour awaiting device verification

## Baseline (recorded before any changes)

- Project: `EgressMapper/` — xcodegen (`project.yml`), SwiftUI, iOS 17.0, Swift 5 language mode.
- Build: **succeeds** for `iOS Simulator` and `generic/platform=iOS` (signed, team `553SS7SNPX`).
- Tests: **58 passing, 0 failures.**

## Existing architecture (inspected)

| Concern | Location |
|---|---|
| Saved zone metadata | `Models/MappingZone.swift` → `zone.json` |
| Captured waypoints | `Models/Waypoint.swift`, `WaypointType.swift` → `waypoints.json` |
| Recorded path | `Models/RoutePath.swift` (`PathPoint`, RDP simplify) → `path.json` |
| AR anchors | `ARSessionManager.addWaypoint` — `ARAnchor(name: "wp:<uuid>")` |
| ARWorldMap storage | `Storage/ZoneFileStore.swift` → `worldmap.arexperience` (NSKeyedArchiver) |
| Route selection | `Views/RouteSetupView.swift` (manual start + destination pickers) |
| Routing | `Routing/RouteGraph.swift` — chain graph + Dijkstra |
| Guidance logic | `Routing/GuidanceEngine.swift` (legs, turns, arrival) |
| AR rendering | `AR/ARRouteRenderer.swift` (chevrons, markers, height modes) |
| Relocalization | `ARSessionManager.startRelocalizing` + `Views/GuidanceView.swift` |
| Tracking interpretation | `Models/TrackingStatus.swift` |
| Persistence root | `Application Support/Zones/<uuid>/` |

## Key architecture decision: `Waypoint` vs `RouteNode`

The existing `Waypoint` is a **capture-time** record — it carries `anchorID`, `pathIndex`,
`detectedText`, i.e. facts about the act of mapping. The emergency router needs a
**graph vertex** with accessibility flags, hazards and synthetic nodes (`temporaryStart`,
`hallwayPoint`) that were never captured by a human.

Rather than overload `Waypoint` (which would force a risky migration of every saved zone),
`RouteNode` is introduced as a derived graph vertex. **`RouteNode.id` is deliberately equal
to the source `Waypoint.id`**, so the two are cheaply cross-referenced and existing AR
anchors keep resolving. `waypoints.json` and `path.json` are never rewritten or deleted.

This is a deliberate separation, not duplication:
- `Waypoint` = "what the administrator physically anchored"
- `RouteNode` = "what the router traverses"

## Migration strategy (non-destructive)

- New file `graph.json`, versioned (`BuildingGraph.version`, current = 1).
- On load: if `graph.json` is absent or stale, rebuild it from `waypoints.json` + `path.json`
  via `GraphMigrator`, then write it. Source files are left untouched.
- A corrupt `graph.json` is discarded and regenerated from source, never fatal.
- Active hazards live in a **separate** `hazards.json` so clearing them never touches the
  permanent graph.

## Milestones

**M1 (this milestone)** — Mode split (Emergency / Configure / Saved Maps); formalize the
route graph (`RouteNode`, `RouteEdge`, `EdgeAccessibility`, `RouteHazard`,
`BuildingGraph`); `NavigationProfile`; `RoutePosition`; profile-aware
`ShortestPathService`; temporary start-node insertion; migration + tests.

**M2** — "I Don't Know Where I Am": relocalize → snap camera pose to nearest edge →
`LocationEstimate` + confidence → confirmation screen → manual fallback. *Device test gate.*

**M3** — Automatic exit selection across all exits; accessibility-aware routing UI.

**M4** — Manual hazard reporting, edge blocking, dynamic rerouting, full teardown of stale
AR anchors before re-render. *Device test gate.*

**M5** — Room-sign OCR as a localization aid; voice reports (deterministic parser);
guidance polish; tracking-loss recovery.

## Routing rules (fixed now, used by all later milestones)

- A blocked edge is **excluded from the graph**, never given a large finite cost.
- Profile violations (`avoidStairs`, `requireWheelchairAccessible`, `avoidElevators`)
  exclude edges outright — never silently downweighted.
- Non-blocking hazards apply a multiplicative penalty proportional to severity.
- No valid route produces a typed, explainable error — never a silent fallback.

## Out of scope this milestone

LiDAR, RoomPlan, backend, web dashboard, external AI APIs, multi-floor navigation.


## Completion status (2026-08-06)

All five milestones are implemented. 171 unit tests pass; simulator and signed
device builds are clean.

| Milestone | State |
|---|---|
| M1 modes + route graph + migration | Implemented, tested |
| M2 "I Don't Know Where I Am" | Implemented, tested (AR unverified) |
| M3 automatic exit + accessibility | Implemented, tested |
| M4 hazard reporting + rerouting | Implemented, tested (AR unverified) |
| M5 OCR, voice, guidance, recovery | Implemented, tested (AR/speech unverified) |

### Not verified by any automated test

Every ARKit, camera, microphone and haptic behaviour. The Simulator provides
none of these. Specifically unproven: relocalization success, location accuracy,
arrow alignment, teardown of stale arrows on reroute, speech recognition, and
haptic patterns. See `docs/testing/emergency-navigation-device-tests.md`.

### Known limitations

- Graph edges derive from walk order, so a single recorded pass yields a single
  path. Branching requires multiple mapping passes.
- Corridor aliasing is undetected: relocalization can match the wrong stretch of
  a repetitive hallway and would then be confidently wrong. Manual fallback and
  sign scanning are always reachable for this reason.
- Hazards are device-local and persist until cleared; no expiry, no sharing.
- "Relocalize" is offered via the tracking-lost dialog rather than as a
  permanently visible control.
- Multi-floor navigation, backend, and voice-driven segment targeting beyond the
  segment ahead remain out of scope.
