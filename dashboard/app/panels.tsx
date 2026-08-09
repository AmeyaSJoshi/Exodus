"use client";

import { useEffect, useState } from "react";
import type { AuditEntry, LiveEdgeState, RouteEdge, RouteNode, UserReport } from "@/lib/supabase";
import {
  HAZARDS,
  REPORT_LABEL,
  STATUS_META,
  TONE_CLASS,
  type EdgeStatus,
  type HazardType,
  type Tone,
  availabilityFor,
  hazardIcon,
  hazardLabel,
  relativeTime,
} from "@/lib/model";

export function Badge({ tone = "neutral", children }: { tone?: Tone; children: React.ReactNode }) {
  return (
    <span className={`inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs font-medium ${TONE_CLASS[tone]}`}>
      {children}
    </span>
  );
}

export function Panel({
  title,
  count,
  children,
}: {
  title: string;
  count?: number;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded-xl border border-hairline bg-surface">
      <header className="flex items-center justify-between border-b border-hairline px-4 py-3">
        <h2 className="text-sm font-semibold tracking-wide text-ink uppercase">{title}</h2>
        {count !== undefined && count > 0 && (
          <span className="rounded-full bg-surface-2 px-2 py-0.5 text-xs text-ink-2">{count}</span>
        )}
      </header>
      <div className="p-4">{children}</div>
    </section>
  );
}

export function Empty({ children }: { children: React.ReactNode }) {
  return <p className="py-2 text-sm text-ink-3">{children}</p>;
}

/**
 * Inspector for one segment.
 *
 * Everything here goes through `set_edge_state` / `clear_edge_state`, the same
 * RPCs the phones read from — there is no second incident model.
 */
export function Inspector({
  edge,
  nodeByStable,
  state,
  onPublish,
  onClear,
  busy,
}: {
  edge: RouteEdge | null;
  nodeByStable: Record<string, RouteNode>;
  state: LiveEdgeState | undefined;
  onPublish: (input: {
    status: Exclude<EdgeStatus, "available">;
    hazard: HazardType;
    reason: string;
    severity: number;
    expiresAt: string | null;
  }) => Promise<void>;
  onClear: () => Promise<void>;
  busy: boolean;
}) {
  const [status, setStatus] = useState<Exclude<EdgeStatus, "available">>("blocked");
  const [hazard, setHazard] = useState<HazardType>("blockedHallway");
  const [reason, setReason] = useState("");
  const [severity, setSeverity] = useState(3);
  const [expiresIn, setExpiresIn] = useState("0");

  // Reset the form when a different segment is selected, so a reason typed for
  // one hallway cannot be published against another.
  useEffect(() => {
    if (!edge) return;
    setStatus(state && state.status !== "available" ? state.status : "blocked");
    setHazard((state?.hazard_type as HazardType) ?? "blockedHallway");
    setReason(state?.reason ?? "");
    setSeverity(state?.severity ?? 3);
    setExpiresIn("0");
  }, [edge, state]);

  if (!edge) {
    return (
      <Panel title="Incident">
        <Empty>Select a segment on the floor plan to publish or clear an incident.</Empty>
      </Panel>
    );
  }

  const from = nodeByStable[edge.from_node_stable_id]?.name ?? "—";
  const to = nodeByStable[edge.to_node_stable_id]?.name ?? "—";
  const current = state?.status ?? "available";
  const meta = STATUS_META[current];
  const effect = availabilityFor(status, hazard);

  return (
    <Panel title="Incident">
      <div className="space-y-4">
        <div>
          <p className="text-base font-semibold leading-snug">
            {from} <span className="text-ink-3">→</span> {to}
          </p>
          <p className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-ink-2">
            <span>{Math.round(edge.distance_meters)} m</span>
            {edge.contains_stairs && <span>· stairs</span>}
            {edge.requires_elevator && <span>· elevator</span>}
            {!edge.wheelchair_accessible && <span>· not step-free</span>}
          </p>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <Badge tone={meta.tone}>
              {meta.icon} {meta.label}
            </Badge>
            {state?.hazard_type && current !== "available" && (
              <Badge tone="neutral">
                {hazardIcon(state.hazard_type)} {hazardLabel(state.hazard_type)}
              </Badge>
            )}
          </div>
          {state?.reason && current !== "available" && (
            <p className="mt-2 text-sm text-ink-2">{state.reason}</p>
          )}
        </div>

        <div className="grid gap-3 border-t border-hairline pt-4">
          <Field label="Status">
            <div className="flex gap-2">
              {(["blocked", "restricted"] as const).map((s) => (
                <button
                  key={s}
                  type="button"
                  aria-pressed={status === s}
                  onClick={() => setStatus(s)}
                  className={`flex-1 rounded-md border px-3 py-2 text-sm font-medium transition ${
                    status === s ? TONE_CLASS[STATUS_META[s].tone] : "border-hairline bg-surface-2 text-ink-2"
                  }`}
                >
                  {STATUS_META[s].label}
                </button>
              ))}
            </div>
          </Field>

          <Field label="Hazard type">
            <select
              aria-label="Hazard type"
              value={hazard}
              onChange={(e) => setHazard(e.target.value as HazardType)}
              className="w-full rounded-md border border-hairline bg-surface-2 px-3 py-2 text-sm"
            >
              {HAZARDS.map((h) => (
                <option key={h.value} value={h.value}>
                  {h.icon} {h.label}
                </option>
              ))}
            </select>
          </Field>

          <Field label={`Severity — ${severity}`}>
            <input
              aria-label="Severity"
              type="range"
              min={1}
              max={5}
              value={severity}
              onChange={(e) => setSeverity(Number(e.target.value))}
              className="w-full accent-[var(--color-critical)]"
            />
          </Field>

          <Field label="Reason">
            <input
              aria-label="Reason"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="Visible to occupants"
              className="w-full rounded-md border border-hairline bg-surface-2 px-3 py-2 text-sm placeholder:text-ink-3"
            />
          </Field>

          <Field label="Expires">
            <select
              aria-label="Expires"
              value={expiresIn}
              onChange={(e) => setExpiresIn(e.target.value)}
              className="w-full rounded-md border border-hairline bg-surface-2 px-3 py-2 text-sm"
            >
              <option value="0">Until cleared</option>
              <option value="15">In 15 minutes</option>
              <option value="60">In 1 hour</option>
              <option value="240">In 4 hours</option>
            </select>
          </Field>

          <p className="rounded-md bg-surface-2 px-3 py-2 text-xs text-ink-2">
            {effect.kind === "unavailable"
              ? "Routing effect: this segment becomes impassable. Routes using it are recalculated."
              : `Routing effect: passable at ${effect.kind === "discouraged" ? `${effect.costMultiplier}×` : "1×"} cost — used only when no better route exists.`}
          </p>

          <div className="flex gap-2">
            <button
              type="button"
              disabled={busy}
              onClick={() =>
                onPublish({
                  status,
                  hazard,
                  reason,
                  severity,
                  expiresAt:
                    expiresIn === "0"
                      ? null
                      : new Date(Date.now() + Number(expiresIn) * 60_000).toISOString(),
                })
              }
              className="flex-1 rounded-md bg-critical px-3 py-2.5 text-sm font-semibold text-white disabled:opacity-50"
            >
              {busy ? "Publishing…" : "Publish incident"}
            </button>
            <button
              type="button"
              disabled={busy || current === "available"}
              onClick={onClear}
              className="rounded-md border border-hairline bg-surface-2 px-4 py-2.5 text-sm font-semibold disabled:opacity-40"
            >
              Clear
            </button>
          </div>
        </div>
      </div>
    </Panel>
  );
}

/**
 * Label + control. Deliberately a plain element rather than a `<label>`: a
 * click anywhere on a label is re-dispatched to the first labelable control
 * inside it, which swallowed every tap on the Blocked/Restricted buttons.
 * Controls carry their own `aria-label` instead.
 */
function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1.5">
      <span className="block text-xs font-medium text-ink-2">{label}</span>
      {children}
    </div>
  );
}

/** Occupant-submitted reports awaiting a decision. */
export function PendingReports({
  reports,
  nodeByStable,
  edges,
  onReview,
  busyID,
}: {
  reports: UserReport[];
  nodeByStable: Record<string, RouteNode>;
  edges: RouteEdge[];
  onReview: (report: UserReport, status: "verified" | "rejected") => Promise<void>;
  busyID: string | null;
}) {
  function where(r: UserReport): string {
    if (r.edge_stable_id) {
      const e = edges.find((x) => x.stable_id === r.edge_stable_id);
      if (e) {
        return `${nodeByStable[e.from_node_stable_id]?.name ?? "?"} → ${nodeByStable[e.to_node_stable_id]?.name ?? "?"}`;
      }
    }
    if (r.node_stable_id) {
      const n = Object.values(nodeByStable).find((x) => x.stable_id === r.node_stable_id);
      if (n) return n.name;
    }
    return "Unknown location";
  }

  return (
    <Panel title="Pending reports" count={reports.length}>
      {!reports.length && <Empty>No occupant reports awaiting review.</Empty>}
      <ul className="space-y-3">
        {reports.map((r) => (
          <li key={r.id} className="rounded-lg border border-hairline bg-surface-2 p-3">
            <div className="flex items-start justify-between gap-2">
              <div className="min-w-0">
                <p className="truncate text-sm font-semibold">
                  {hazardIcon(r.report_type)} {REPORT_LABEL[r.report_type] ?? r.report_type}
                </p>
                <p className="truncate text-xs text-ink-2">{where(r)}</p>
              </div>
              <span className="shrink-0 text-xs text-ink-3">{relativeTime(r.created_at)}</span>
            </div>
            {r.description && <p className="mt-2 text-sm text-ink-2">{r.description}</p>}
            <p className="mt-1 text-xs text-ink-3">
              {r.reporter_id ? `Reporter ${r.reporter_id.slice(0, 8)}` : "Anonymous reporter"}
            </p>
            <div className="mt-3 flex gap-2">
              <button
                type="button"
                disabled={busyID === r.id}
                onClick={() => onReview(r, "verified")}
                className="flex-1 rounded-md bg-critical px-3 py-2 text-sm font-semibold text-white disabled:opacity-50"
              >
                Verify &amp; publish
              </button>
              <button
                type="button"
                disabled={busyID === r.id}
                onClick={() => onReview(r, "rejected")}
                className="rounded-md border border-hairline px-3 py-2 text-sm font-medium text-ink-2 disabled:opacity-50"
              >
                Reject
              </button>
            </div>
          </li>
        ))}
      </ul>
    </Panel>
  );
}

/** Currently published incidents, newest first. */
export function ActiveIncidents({
  live,
  edges,
  nodeByStable,
  onSelect,
}: {
  live: Record<string, LiveEdgeState>;
  edges: RouteEdge[];
  nodeByStable: Record<string, RouteNode>;
  onSelect: (e: RouteEdge) => void;
}) {
  const active = Object.values(live).filter((s) => s.status !== "available");

  return (
    <Panel title="Active incidents" count={active.length}>
      {!active.length && <Empty>No active incidents. Every mapped route is available.</Empty>}
      <ul className="space-y-2">
        {active.map((s) => {
          const e = edges.find((x) => x.stable_id === s.edge_stable_id);
          const meta = STATUS_META[s.status];
          return (
            <li key={s.edge_stable_id}>
              <button
                type="button"
                onClick={() => e && onSelect(e)}
                disabled={!e}
                className="w-full rounded-lg border border-hairline bg-surface-2 p-3 text-left transition hover:border-ink-3 disabled:opacity-60"
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="min-w-0 truncate text-sm font-medium">
                    {e
                      ? `${nodeByStable[e.from_node_stable_id]?.name ?? "?"} → ${nodeByStable[e.to_node_stable_id]?.name ?? "?"}`
                      : "Segment not on this map version"}
                  </span>
                  <Badge tone={meta.tone}>
                    {meta.icon} {meta.label}
                  </Badge>
                </div>
                <p className="mt-1 text-xs text-ink-2">
                  {hazardIcon(s.hazard_type)} {hazardLabel(s.hazard_type)} · severity {s.severity}
                  {s.expires_at && ` · expires ${new Date(s.expires_at).toLocaleTimeString()}`}
                </p>
                {s.reason && <p className="mt-1 truncate text-xs text-ink-3">{s.reason}</p>}
              </button>
            </li>
          );
        })}
      </ul>
    </Panel>
  );
}

/** Append-only record of who changed what. */
export function ActivityFeed({
  entries,
  edges,
  nodeByStable,
}: {
  entries: AuditEntry[];
  edges: RouteEdge[];
  nodeByStable: Record<string, RouteNode>;
}) {
  function describe(a: AuditEntry): { text: string; tone: Tone } {
    const e = edges.find((x) => x.stable_id === a.target_id);
    const where = e
      ? `${nodeByStable[e.from_node_stable_id]?.name ?? "?"} → ${nodeByStable[e.to_node_stable_id]?.name ?? "?"}`
      : "a segment";
    const status = a.new_state?.status ?? "available";
    if (status === "available") return { text: `Cleared ${where}`, tone: "safe" };
    if (status === "restricted") return { text: `Restricted ${where}`, tone: "caution" };
    return { text: `Blocked ${where}`, tone: "critical" };
  }

  return (
    <Panel title="Live activity">
      {!entries.length && <Empty>Nothing has changed yet in this building.</Empty>}
      <ol className="space-y-2.5">
        {entries.map((a) => {
          const d = describe(a);
          return (
            <li key={a.id} className="flex items-start gap-2.5 text-sm">
              <span
                aria-hidden
                className={`mt-1.5 h-2 w-2 shrink-0 rounded-full ${
                  d.tone === "safe" ? "bg-safe" : d.tone === "caution" ? "bg-caution" : "bg-critical"
                }`}
              />
              <span className="min-w-0 flex-1">
                <span className="block truncate">{d.text}</span>
                <span className="text-xs text-ink-3">
                  {relativeTime(a.created_at)}
                  {a.new_state?.hazard_type && ` · ${hazardLabel(a.new_state.hazard_type)}`}
                </span>
              </span>
            </li>
          );
        })}
      </ol>
    </Panel>
  );
}
