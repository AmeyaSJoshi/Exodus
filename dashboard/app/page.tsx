"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  supabase,
  type AuditEntry,
  type Building,
  type LiveEdgeState,
  type MapVersion,
  type Profile,
  type RouteEdge,
  type RouteNode,
  type UserReport,
} from "@/lib/supabase";
import { type EdgeStatus, type HazardType } from "@/lib/model";
import { GraphView } from "./graph";
import { ActiveIncidents, ActivityFeed, Badge, Inspector, PendingReports } from "./panels";

type Conn = "connecting" | "live" | "error" | "idle";

export default function Page() {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  if (!ready) {
    return (
      <main className="flex min-h-screen items-center justify-center text-ink-2">Loading…</main>
    );
  }
  if (!session) return <LoginForm />;
  return <Console session={session} onSignOut={() => supabase.auth.signOut()} />;
}

function Wordmark({ className = "" }: { className?: string }) {
  return (
    <span className={`flex items-baseline gap-1.5 ${className}`}>
      <span className="font-extrabold tracking-[0.18em]">EGRESS</span>
      <span aria-hidden className="h-1.5 w-1.5 rounded-full bg-critical" />
    </span>
  );
}

function LoginForm() {
  const [email, setEmail] = useState("admin@egress.test");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) setError(error.message);
    setBusy(false);
  }

  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <form onSubmit={submit} className="w-full max-w-sm space-y-5 rounded-2xl border border-hairline bg-surface p-7">
        <div className="space-y-1">
          <Wordmark className="text-2xl" />
          <p className="text-sm text-ink-2">Emergency command console</p>
        </div>
        <label className="block space-y-1.5">
          <span className="text-xs font-medium text-ink-2">Email</span>
          <input
            className="w-full rounded-md border border-hairline bg-surface-2 px-3 py-2.5 text-sm"
            type="email" autoComplete="username" value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </label>
        <label className="block space-y-1.5">
          <span className="text-xs font-medium text-ink-2">Password</span>
          <input
            className="w-full rounded-md border border-hairline bg-surface-2 px-3 py-2.5 text-sm"
            type="password" autoComplete="current-password" value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </label>
        {error && (
          <p className="rounded-md border border-critical/40 bg-critical-dim px-3 py-2 text-sm text-critical">
            {error}
          </p>
        )}
        <button
          disabled={busy || !password}
          className="w-full rounded-md bg-critical px-3 py-2.5 text-sm font-semibold text-white disabled:opacity-50"
        >
          {busy ? "Signing in…" : "Sign in"}
        </button>
      </form>
    </main>
  );
}

function Console({ session, onSignOut }: { session: Session; onSignOut: () => void }) {
  const [buildings, setBuildings] = useState<Building[]>([]);
  const [buildingID, setBuildingID] = useState<string | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [mapVersion, setMapVersion] = useState<MapVersion | null>(null);
  const [nodes, setNodes] = useState<RouteNode[]>([]);
  const [edges, setEdges] = useState<RouteEdge[]>([]);
  const [live, setLive] = useState<Record<string, LiveEdgeState>>({});
  const [reports, setReports] = useState<UserReport[]>([]);
  const [audit, setAudit] = useState<AuditEntry[]>([]);
  const [conn, setConn] = useState<Conn>("idle");
  const [selected, setSelected] = useState<RouteEdge | null>(null);
  const [floor, setFloor] = useState("all");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [busyReport, setBusyReport] = useState<string | null>(null);
  const channelRef = useRef<ReturnType<typeof supabase.channel> | null>(null);

  const revision = useMemo(
    () => Object.values(live).reduce((max, s) => Math.max(max, s.revision), 0),
    [live],
  );

  useEffect(() => {
    void (async () => {
      const [b, p] = await Promise.all([
        supabase.from("buildings").select("*").order("name"),
        supabase.from("profiles").select("*").eq("id", session.user.id).maybeSingle(),
      ]);
      if (b.error) setError(b.error.message);
      setBuildings(b.data ?? []);
      setBuildingID((current) => current ?? b.data?.[0]?.id ?? null);
      setProfile(p.data ?? null);
    })();
  }, [session.user.id]);

  const building = buildings.find((b) => b.id === buildingID) ?? null;

  const loadBuilding = useCallback(async () => {
    if (!building) return;
    setSelected(null);
    if (!building.active_map_version_id) {
      setNodes([]); setEdges([]); setMapVersion(null);
      return;
    }
    const mv = building.active_map_version_id;
    const [n, e, l, r, a, v] = await Promise.all([
      supabase.from("route_nodes").select("*").eq("map_version_id", mv),
      supabase.from("route_edges").select("*").eq("map_version_id", mv),
      supabase.from("live_edge_states").select("*").eq("building_id", building.id),
      supabase.from("user_reports").select("*").eq("building_id", building.id)
        .eq("status", "pending").order("created_at", { ascending: false }),
      supabase.from("live_state_audit").select("*").eq("building_id", building.id)
        .order("created_at", { ascending: false }).limit(25),
      supabase.from("map_versions").select("id,version,status,published_at").eq("id", mv).maybeSingle(),
    ]);
    const first = [n, e, l].find((x) => x.error);
    if (first?.error) return setError(first.error.message);
    setNodes(n.data ?? []);
    setEdges(e.data ?? []);
    setLive(Object.fromEntries((l.data ?? []).map((s: LiveEdgeState) => [s.edge_stable_id, s])));
    // Reports and audit are admin-only reads; an occupant signing in here simply
    // sees empty panels rather than an error.
    setReports(r.data ?? []);
    setAudit(a.data ?? []);
    setMapVersion(v.data ?? null);
  }, [building]);

  useEffect(() => { void loadBuilding(); }, [loadBuilding]);

  // Realtime. The snapshot loaded above is authoritative; events only advance
  // it, and anything at or below a revision we already hold is ignored.
  useEffect(() => {
    if (!buildingID) return;
    if (channelRef.current) void supabase.removeChannel(channelRef.current);
    setConn("connecting");

    const channel = supabase
      .channel(`live-${buildingID}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "live_edge_states", filter: `building_id=eq.${buildingID}` },
        (payload) => {
          const row = (payload.new ?? payload.old) as LiveEdgeState | undefined;
          if (!row?.edge_stable_id) return;
          setLive((prev) => {
            const existing = prev[row.edge_stable_id];
            if (existing && row.revision <= existing.revision) return prev;
            return { ...prev, [row.edge_stable_id]: row };
          });
          void refreshActivity(buildingID);
        },
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "user_reports", filter: `building_id=eq.${buildingID}` },
        () => void refreshReports(buildingID),
      )
      .subscribe((status) => {
        setConn(
          status === "SUBSCRIBED" ? "live"
          : status === "CHANNEL_ERROR" || status === "TIMED_OUT" ? "error"
          : "connecting",
        );
      });

    channelRef.current = channel;
    return () => { void supabase.removeChannel(channel); };
  }, [buildingID]);

  async function refreshReports(id: string) {
    const { data } = await supabase.from("user_reports").select("*").eq("building_id", id)
      .eq("status", "pending").order("created_at", { ascending: false });
    setReports(data ?? []);
  }

  async function refreshActivity(id: string) {
    const { data } = await supabase.from("live_state_audit").select("*").eq("building_id", id)
      .order("created_at", { ascending: false }).limit(25);
    setAudit(data ?? []);
  }

  const nodeByStable = useMemo(
    () => Object.fromEntries(nodes.map((n) => [n.stable_id, n])),
    [nodes],
  );

  const floors = useMemo(
    () => Array.from(new Set(nodes.map((n) => n.floor_id))).sort(),
    [nodes],
  );

  const visibleNodes = floor === "all" ? nodes : nodes.filter((n) => n.floor_id === floor);
  const visibleEdges = edges.filter((e) => {
    const a = nodeByStable[e.from_node_stable_id];
    const b = nodeByStable[e.to_node_stable_id];
    return a && b && (floor === "all" || (a.floor_id === floor && b.floor_id === floor));
  });

  async function publish(input: {
    status: Exclude<EdgeStatus, "available">;
    hazard: HazardType;
    reason: string;
    severity: number;
    expiresAt: string | null;
  }) {
    if (!building || !selected) return;
    setBusy(true);
    setError(null);
    const { error } = await supabase.rpc("set_edge_state", {
      p_building_id: building.id,
      p_edge_stable_id: selected.stable_id,
      p_status: input.status,
      p_hazard_type: input.hazard,
      p_reason: input.reason || null,
      p_severity: input.severity,
      p_expires_at: input.expiresAt,
    });
    setBusy(false);
    if (error) setError(error.message);
  }

  async function clear() {
    if (!building || !selected) return;
    setBusy(true);
    setError(null);
    const { error } = await supabase.rpc("clear_edge_state", {
      p_building_id: building.id,
      p_edge_stable_id: selected.stable_id,
    });
    setBusy(false);
    if (error) setError(error.message);
  }

  // Verification goes through review_report, which writes the building-wide
  // live state in the same transaction. The dashboard never publishes the
  // hazard itself, so a report can never be marked reviewed without its
  // closure landing.
  async function review(report: UserReport, status: "verified" | "rejected") {
    setBusyReport(report.id);
    setError(null);
    const { error } = await supabase.rpc("review_report", {
      p_report_id: report.id,
      p_status: status,
      p_hazard_type: report.report_type,
      p_reason: report.description,
      p_severity: 4,
    });
    setBusyReport(null);
    if (error) return setError(error.message);
    setReports((prev) => prev.filter((r) => r.id !== report.id));
  }

  const connMeta =
    conn === "live" ? { tone: "safe" as const, label: "Live" }
    : conn === "error" ? { tone: "critical" as const, label: "Disconnected" }
    : { tone: "caution" as const, label: "Connecting…" };

  return (
    <div className="min-h-screen">
      <header className="sticky top-0 z-10 border-b border-hairline bg-ground/95 backdrop-blur">
        <div className="mx-auto flex max-w-[1600px] flex-wrap items-center gap-x-4 gap-y-3 px-5 py-3">
          <Wordmark className="text-lg" />

          <div className="flex flex-wrap items-center gap-2">
            <select
              aria-label="Building"
              className="rounded-md border border-hairline bg-surface-2 px-2.5 py-1.5 text-sm"
              value={buildingID ?? ""}
              onChange={(e) => setBuildingID(e.target.value)}
            >
              {buildings.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
              {!buildings.length && <option value="">No buildings</option>}
            </select>
            <select
              aria-label="Floor"
              className="rounded-md border border-hairline bg-surface-2 px-2.5 py-1.5 text-sm"
              value={floor}
              onChange={(e) => setFloor(e.target.value)}
            >
              <option value="all">All floors</option>
              {floors.map((f) => <option key={f} value={f}>{f}</option>)}
            </select>
          </div>

          <div className="flex flex-wrap items-center gap-2">
            <Badge tone={connMeta.tone}>
              <span aria-hidden>{conn === "live" ? "◉" : conn === "error" ? "✕" : "◌"}</span>
              {connMeta.label}
            </Badge>
            {mapVersion && <Badge tone="neutral">Map v{mapVersion.version}</Badge>}
          </div>

          <div className="ml-auto flex items-center gap-3">
            <span className="hidden text-right text-xs leading-tight sm:block">
              <span className="block font-medium">{profile?.display_name ?? session.user.email}</span>
              <span className="block text-ink-3 capitalize">{profile?.role ?? "unknown role"}</span>
            </span>
            <button
              onClick={onSignOut}
              className="rounded-md border border-hairline px-3 py-1.5 text-sm text-ink-2"
            >
              Sign out
            </button>
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-[1600px] space-y-4 p-5">
        {error && (
          <p role="alert" className="rounded-lg border border-critical/40 bg-critical-dim px-4 py-3 text-sm text-critical">
            {error}
          </p>
        )}

        <div className="grid items-start gap-4 xl:grid-cols-[minmax(0,1fr)_380px]">
          <div className="space-y-4">
            <GraphView
              nodes={visibleNodes}
              edges={visibleEdges}
              nodeByStable={nodeByStable}
              live={live}
              selected={selected}
              onSelect={setSelected}
            />
            <div className="grid gap-4 md:grid-cols-2 xl:hidden">
              <ActiveIncidents live={live} edges={edges} nodeByStable={nodeByStable} onSelect={setSelected} />
              <ActivityFeed entries={audit} edges={edges} nodeByStable={nodeByStable} />
            </div>
          </div>

          <div className="space-y-4">
            <Inspector
              edge={selected}
              nodeByStable={nodeByStable}
              state={selected ? live[selected.stable_id] : undefined}
              onPublish={publish}
              onClear={clear}
              busy={busy}
            />
            <PendingReports
              reports={reports}
              nodeByStable={nodeByStable}
              edges={edges}
              onReview={review}
              busyID={busyReport}
            />
            <div className="hidden space-y-4 xl:block">
              <ActiveIncidents live={live} edges={edges} nodeByStable={nodeByStable} onSelect={setSelected} />
              <ActivityFeed entries={audit} edges={edges} nodeByStable={nodeByStable} />
            </div>
          </div>
        </div>

        <p className="pt-2 text-xs text-ink-3">
          Experimental prototype. Live state advises the EGRESS apps; it does not replace
          building fire-alarm or life-safety systems. Revision {revision}.
        </p>
      </main>
    </div>
  );
}
