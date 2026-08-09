/**
 * Presentation and routing semantics shared by every dashboard panel.
 *
 * The hazard vocabulary and the live-state statuses mirror `RouteHazardType`
 * and `LiveEdgeStatus` in the iOS app. Both surfaces read the same rows, so
 * they must agree on what a row means; this file is the one place the dashboard
 * decides that.
 */

export type EdgeStatus = "available" | "blocked" | "restricted";

export type HazardType =
  | "blockedHallway"
  | "lockedDoor"
  | "smoke"
  | "fire"
  | "unavailableStairwell"
  | "unavailableElevator"
  | "crowding"
  | "other";

/**
 * What a hazard does to routing.
 *
 * `unavailable` removes the edge outright — a blocked edge is impossible, never
 * merely expensive. `discouraged` keeps it usable at a cost, which is the right
 * answer for conditions a person can still pass through.
 */
export type Availability =
  | { kind: "available" }
  | { kind: "discouraged"; costMultiplier: number }
  | { kind: "unavailable" };

export const HAZARDS: {
  value: HazardType;
  label: string;
  icon: string;
  /** Availability when this hazard is published as `restricted`. */
  restricted: Availability;
}[] = [
  { value: "blockedHallway", label: "Obstruction", icon: "⛔", restricted: { kind: "discouraged", costMultiplier: 4 } },
  { value: "smoke", label: "Smoke", icon: "🌫", restricted: { kind: "discouraged", costMultiplier: 6 } },
  { value: "fire", label: "Fire", icon: "🔥", restricted: { kind: "unavailable" } },
  { value: "lockedDoor", label: "Locked door", icon: "🔒", restricted: { kind: "unavailable" } },
  { value: "unavailableStairwell", label: "Stairwell failure", icon: "🪜", restricted: { kind: "unavailable" } },
  { value: "unavailableElevator", label: "Elevator failure", icon: "🛗", restricted: { kind: "unavailable" } },
  { value: "crowding", label: "Crowding", icon: "👥", restricted: { kind: "discouraged", costMultiplier: 2.5 } },
  { value: "other", label: "Other", icon: "⚠️", restricted: { kind: "discouraged", costMultiplier: 3 } },
];

export function hazardLabel(type: string | null | undefined): string {
  if (!type) return "Unspecified";
  return HAZARDS.find((h) => h.value === type)?.label ?? type;
}

export function hazardIcon(type: string | null | undefined): string {
  if (!type) return "⚠️";
  return HAZARDS.find((h) => h.value === type)?.icon ?? "⚠️";
}

/** Resolves a published live row into what routing should actually do. */
export function availabilityFor(status: EdgeStatus, hazard: string | null): Availability {
  if (status === "available") return { kind: "available" };
  if (status === "blocked") return { kind: "unavailable" };
  const entry = HAZARDS.find((h) => h.value === hazard);
  return entry?.restricted ?? { kind: "discouraged", costMultiplier: 3 };
}

export const STATUS_META: Record<EdgeStatus, { label: string; tone: Tone; icon: string }> = {
  available: { label: "Available", tone: "safe", icon: "✓" },
  restricted: { label: "Restricted", tone: "caution", icon: "!" },
  blocked: { label: "Blocked", tone: "critical", icon: "✕" },
};

export type Tone = "safe" | "caution" | "critical" | "info" | "neutral";

export const TONE_CLASS: Record<Tone, string> = {
  safe: "bg-safe-dim text-safe border-safe/40",
  caution: "bg-caution-dim text-caution border-caution/40",
  critical: "bg-critical-dim text-critical border-critical/40",
  info: "bg-info-dim text-info border-info/40",
  neutral: "bg-surface-2 text-ink-2 border-hairline",
};

/** Map presentation for each node type. Shape carries the meaning; colour only reinforces it. */
export const NODE_META: Record<
  string,
  { label: string; short: string; color: string; shape: "circle" | "square" | "diamond" | "triangle"; r: number }
> = {
  exit: { label: "Exit", short: "EXIT", color: "#29b873", shape: "triangle", r: 10 },
  refugeArea: { label: "Refuge area", short: "REF", color: "#2dd4bf", shape: "diamond", r: 9 },
  stairwell: { label: "Stairwell", short: "STR", color: "#a855f7", shape: "square", r: 8 },
  elevator: { label: "Elevator", short: "ELV", color: "#14b8a6", shape: "square", r: 8 },
  room: { label: "Room", short: "RM", color: "#3f8cff", shape: "circle", r: 7 },
  intersection: { label: "Intersection", short: "INT", color: "#f2a32a", shape: "circle", r: 6 },
  hallwayPoint: { label: "Hallway", short: "HW", color: "#6b7280", shape: "circle", r: 4 },
};

export function nodeMeta(type: string) {
  return NODE_META[type] ?? NODE_META.hallwayPoint;
}

/** Report kinds an occupant can submit, matching the iOS report sheet. */
export const REPORT_LABEL: Record<string, string> = {
  blockedHallway: "Hallway blocked",
  lockedDoor: "Door locked",
  smoke: "Smoke",
  fire: "Fire",
  unavailableStairwell: "Stairs unavailable",
  unavailableElevator: "Elevator unavailable",
  crowding: "Crowding",
  other: "Other",
};

export function relativeTime(iso: string): string {
  const seconds = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}
