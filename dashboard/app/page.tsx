"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  supabase,
  type Building,
  type LiveEdgeState,
  type RouteEdge,
  type RouteNode,
} from "@/lib/supabase";

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

  if (!ready) return <Centered>Loading…</Centered>;
  if (!session) return <LoginForm />;
  return <Console onSignOut={() => supabase.auth.signOut()} />;
}

function Centered({ children }: { children: React.ReactNode }) {
  return <div className="flex min-h-screen items-center justify-center text-zinc-400">{children}</div>;
}

function LoginForm() {
  const [email, setEmail] = useState("admin@egress.test");
  const [password, setPassword] = useState("egress-admin-pw");
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
    <div className="flex min-h-screen items-center justify-center p-6">
      <form onSubmit={submit} className="w-full max-w-sm space-y-4 rounded-xl border border-zinc-800 bg-zinc-950 p-6">
        <div>
          <h1 className="text-2xl font-bold">EGRESS Admin</h1>
          <p className="text-sm text-zinc-500">Live building state</p>
        </div>
        <input
          className="w-full rounded-md border border-zinc-800 bg-zinc-900 px-3 py-2 text-sm"
          type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="Email"
        />
        <input
          className="w-full rounded-md border border-zinc-800 bg-zinc-900 px-3 py-2 text-sm"
          type="password" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="Password"
        />
        {error && <p className="text-sm text-red-400">{error}</p>}
        <button
          disabled={busy}
          className="w-full rounded-md bg-emerald-600 px-3 py-2 text-sm font-semibold disabled:opacity-50"
        >
          {busy ? "Signing in…" : "Sign in"}
        </button>
        <p className="text-xs text-zinc-600">
          Local demo credentials come from <code>supabase/seed.sql</code>.
        </p>
      </form>
    </div>
  );
}

function Console({ onSignOut }: { onSignOut: () => void }) {
  const [buildings, setBuildings] = useState<Building[]>([]);
  const [buildingID, setBuildingID] = useState<string | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [nodes, setNodes] = useState<RouteNode[]>([]);
  const [edges, setEdges] = useState<RouteEdge[]>([]);
  const [live, setLive] = useState<Record<string, LiveEdgeState>>({});
  const [conn, setConn] = useState<Conn>("idle");
  const [selected, setSelected] = useState<RouteEdge | null>(null);
  const [reason, setReason] = useState("");
  const [floor, setFloor] = useState<string>("all");
  const [error, setError] = useState<string | null>(null);
  const channelRef = useRef<ReturnType<typeof supabase.channel> | null>(null);

  const revision = useMemo(
    () => Object.values(live).reduce((max, s) => Math.max(max, s.revision), 0),
    [live],
  );

  // Buildings
  useEffect(() => {
    supabase.from("buildings").select("*").order("name").then(({ data, error }) => {
      if (error) return setError(error.message);
      setBuildings(data ?? []);
      if (data?.length && !buildingID) setBuildingID(data[0].id);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const building = buildings.find((b) => b.id === buildingID) ?? null;

  // Removes the building and, by cascade, every version of its map, its
  // artifacts and its live closures. delete_building() re-checks authorization
  // server-side, so an occupant reaching this code still gets refused.
  async function deleteBuilding() {
    if (!building) return;
    const confirmed = window.confirm(
      `Delete "${building.name}"?\n\n` +
        "This permanently removes the building, every published version of its map " +
        "and its live closures, for everyone in your organization. Occupants will " +
        "no longer see it. This cannot be undone.",
    );
    if (!confirmed) return;

    setDeleting(true);
    setError(null);
    const { error } = await supabase.rpc("delete_building", { p_building_id: building.id });
    setDeleting(false);
    if (error) return setError(error.message);

    const remaining = buildings.filter((b) => b.id !== building.id);
    setBuildings(remaining);
    setBuildingID(remaining[0]?.id ?? null);
  }

  // Graph + live state for the selected building
  const loadGraph = useCallback(async () => {
    if (!building?.active_map_version_id) {
      setNodes([]); setEdges([]);
      return;
    }
    const mv = building.active_map_version_id;
    const [n, e, l] = await Promise.all([
      supabase.from("route_nodes").select("*").eq("map_version_id", mv),
      supabase.from("route_edges").select("*").eq("map_version_id", mv),
      supabase.from("live_edge_states").select("*").eq("building_id", building.id),
    ]);
    if (n.error || e.error || l.error) {
      setError(n.error?.message ?? e.error?.message ?? l.error?.message ?? null);
      return;
    }
    setNodes(n.data ?? []);
    setEdges(e.data ?? []);
    setLive(Object.fromEntries((l.data ?? []).map((s: LiveEdgeState) => [s.edge_stable_id, s])));
  }, [building]);

  useEffect(() => { void loadGraph(); }, [loadGraph]);

  // Realtime — resubscribe when the building changes.
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
            // Ignore anything we have already applied.
            if (existing && row.revision <= existing.revision) return prev;
            return { ...prev, [row.edge_stable_id]: row };
          });
        },
      )
      .subscribe((status) => {
        setConn(status === "SUBSCRIBED" ? "live" : status === "CHANNEL_ERROR" || status === "TIMED_OUT" ? "error" : "connecting");
      });

    channelRef.current = channel;
    return () => { void supabase.removeChannel(channel); };
  }, [buildingID]);

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

  async function setStatus(edge: RouteEdge, status: "available" | "blocked") {
    if (!building) return;
    setError(null);
    const { error } =
      status === "available"
        ? await supabase.rpc("clear_edge_state", {
            p_building_id: building.id,
            p_edge_stable_id: edge.stable_id,
          })
        : await supabase.rpc("set_edge_state", {
            p_building_id: building.id,
            p_edge_stable_id: edge.stable_id,
            p_status: "blocked",
            p_hazard_type: "blockedHallway",
            p_reason: reason || "Blocked by administrator",
            p_severity: 5,
            p_expires_at: null,
          });
    if (error) setError(error.message);
  }

  // Demo control — only offered when such an element actually exists.
  const demoEdge = useMemo(() => {
    return edges.find((e) => {
      const a = nodeByStable[e.from_node_stable_id];
      const b = nodeByStable[e.to_node_stable_id];
      return /stair/i.test(a?.name ?? "") || /stair/i.test(b?.name ?? "");
    }) ?? null;
  }, [edges, nodeByStable]);

  const demoBlocked = demoEdge ? live[demoEdge.stable_id]?.status === "blocked" : false;

  return (
    <div className="mx-auto max-w-6xl space-y-4 p-6">
      <header className="flex flex-wrap items-center gap-3">
        <h1 className="text-xl font-bold">EGRESS Admin</h1>
        <span className={`rounded-full px-2 py-0.5 text-xs ${
          conn === "live" ? "bg-emerald-900 text-emerald-300"
          : conn === "error" ? "bg-red-900 text-red-300"
          : "bg-amber-900 text-amber-300"}`}>
          Realtime: {conn}
        </span>
        <span className="rounded-full bg-zinc-800 px-2 py-0.5 text-xs text-zinc-300">revision {revision}</span>
        <div className="ml-auto flex items-center gap-2">
          <select
            className="rounded-md border border-zinc-800 bg-zinc-900 px-2 py-1 text-sm"
            value={buildingID ?? ""} onChange={(e) => setBuildingID(e.target.value)}
          >
            {buildings.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
          <select
            className="rounded-md border border-zinc-800 bg-zinc-900 px-2 py-1 text-sm"
            value={floor} onChange={(e) => setFloor(e.target.value)}
          >
            <option value="all">All floors</option>
            {floors.map((f) => <option key={f} value={f}>{f}</option>)}
          </select>
          <button
            onClick={deleteBuilding}
            disabled={!building || deleting}
            title="Delete this building and all of its map versions"
            className="rounded-md border border-red-900 px-2 py-1 text-sm text-red-300 disabled:opacity-40"
          >
            {deleting ? "Deleting…" : "Delete building"}
          </button>
          <button onClick={onSignOut} className="rounded-md border border-zinc-800 px-2 py-1 text-sm">Sign out</button>
        </div>
      </header>

      {error && <p className="rounded-md bg-red-950 p-3 text-sm text-red-300">{error}</p>}

      {demoEdge && (
        <button
          onClick={() => setStatus(demoEdge, demoBlocked ? "available" : "blocked")}
          className={`w-full rounded-lg px-4 py-3 text-sm font-bold ${
            demoBlocked ? "bg-emerald-600" : "bg-red-600"}`}
        >
          {demoBlocked ? "Clear " : "Block "}
          {nodeByStable[demoEdge.from_node_stable_id]?.name} → {nodeByStable[demoEdge.to_node_stable_id]?.name}
        </button>
      )}

      <div className="grid gap-4 md:grid-cols-[2fr_1fr]">
        <GraphView
          nodes={visibleNodes}
          edges={visibleEdges}
          nodeByStable={nodeByStable}
          live={live}
          selected={selected}
          onSelect={setSelected}
        />

        <aside className="space-y-3 rounded-xl border border-zinc-800 bg-zinc-950 p-4">
          <h2 className="font-semibold">Segment</h2>
          {!selected && <p className="text-sm text-zinc-500">Click a line on the map to edit its status.</p>}
          {selected && (
            <>
              <p className="text-sm">
                {nodeByStable[selected.from_node_stable_id]?.name} →{" "}
                {nodeByStable[selected.to_node_stable_id]?.name}
              </p>
              <p className="text-xs text-zinc-500">
                {selected.distance_meters} m
                {selected.contains_stairs && " · stairs"}
                {selected.requires_elevator && " · elevator"}
                {!selected.wheelchair_accessible && " · not step-free"}
              </p>
              <p className="text-xs">
                Status:{" "}
                <span className={live[selected.stable_id]?.status === "blocked" ? "text-red-400" : "text-emerald-400"}>
                  {live[selected.stable_id]?.status ?? "available"}
                </span>
                {live[selected.stable_id] && ` · rev ${live[selected.stable_id].revision}`}
              </p>
              <input
                className="w-full rounded-md border border-zinc-800 bg-zinc-900 px-2 py-1 text-sm"
                placeholder="Reason (optional)"
                value={reason} onChange={(e) => setReason(e.target.value)}
              />
              <div className="flex gap-2">
                <button onClick={() => setStatus(selected, "blocked")}
                  className="flex-1 rounded-md bg-red-600 px-3 py-2 text-sm font-semibold">Block</button>
                <button onClick={() => setStatus(selected, "available")}
                  className="flex-1 rounded-md bg-emerald-600 px-3 py-2 text-sm font-semibold">Clear</button>
              </div>
            </>
          )}

          <h2 className="pt-2 font-semibold">Active blocks</h2>
          <ul className="space-y-1 text-xs">
            {Object.values(live).filter((s) => s.status !== "available").map((s) => {
              const e = edges.find((x) => x.stable_id === s.edge_stable_id);
              return (
                <li key={s.edge_stable_id} className="text-red-300">
                  {e ? `${nodeByStable[e.from_node_stable_id]?.name} → ${nodeByStable[e.to_node_stable_id]?.name}` : s.edge_stable_id}
                  {s.reason && ` — ${s.reason}`}
                </li>
              );
            })}
            {Object.values(live).every((s) => s.status === "available") && (
              <li className="text-zinc-600">None</li>
            )}
          </ul>
        </aside>
      </div>
    </div>
  );
}

/** Top-down SVG of the graph using the stored node positions (X/Z plane). */
function GraphView({
  nodes, edges, nodeByStable, live, selected, onSelect,
}: {
  nodes: RouteNode[];
  edges: RouteEdge[];
  nodeByStable: Record<string, RouteNode>;
  live: Record<string, LiveEdgeState>;
  selected: RouteEdge | null;
  onSelect: (e: RouteEdge) => void;
}) {
  if (!nodes.length) {
    return (
      <div className="flex h-96 items-center justify-center rounded-xl border border-zinc-800 text-sm text-zinc-500">
        No published map for this building.
      </div>
    );
  }

  const pad = 40;
  const xs = nodes.map((n) => n.position.x);
  const zs = nodes.map((n) => n.position.z);
  const minX = Math.min(...xs), maxX = Math.max(...xs);
  const minZ = Math.min(...zs), maxZ = Math.max(...zs);
  const w = 700, h = 420;
  const sx = (maxX - minX) || 1, sz = (maxZ - minZ) || 1;
  const scale = Math.min((w - pad * 2) / sx, (h - pad * 2) / sz);
  const px = (x: number) => pad + (x - minX) * scale;
  const pz = (z: number) => pad + (z - minZ) * scale;

  const color = (t: string) =>
    t === "exit" ? "#22c55e" : t === "stairwell" ? "#a855f7" : t === "elevator" ? "#14b8a6"
    : t === "room" ? "#3b82f6" : t === "refugeArea" ? "#2dd4bf" : "#f97316";

  return (
    <div className="overflow-x-auto rounded-xl border border-zinc-800 bg-zinc-950 p-2">
      <svg viewBox={`0 0 ${w} ${h}`} className="w-full">
        {edges.map((e) => {
          const a = nodeByStable[e.from_node_stable_id];
          const b = nodeByStable[e.to_node_stable_id];
          if (!a || !b) return null;
          const blocked = live[e.stable_id]?.status === "blocked";
          const isSel = selected?.stable_id === e.stable_id;
          return (
            <g key={e.stable_id} onClick={() => onSelect(e)} className="cursor-pointer">
              <line
                x1={px(a.position.x)} y1={pz(a.position.z)}
                x2={px(b.position.x)} y2={pz(b.position.z)}
                stroke={blocked ? "#ef4444" : isSel ? "#facc15" : "#52525b"}
                strokeWidth={isSel ? 6 : 4}
                strokeDasharray={blocked ? "8 6" : undefined}
              />
              {/* Wider invisible hit area so thin lines are still clickable. */}
              <line
                x1={px(a.position.x)} y1={pz(a.position.z)}
                x2={px(b.position.x)} y2={pz(b.position.z)}
                stroke="transparent" strokeWidth={18}
              />
            </g>
          );
        })}
        {nodes.map((n) => (
          <g key={n.stable_id}>
            <circle cx={px(n.position.x)} cy={pz(n.position.z)} r={8} fill={color(n.type)} />
            <text
              x={px(n.position.x)} y={pz(n.position.z) - 14}
              textAnchor="middle" fontSize="11" fill="#d4d4d8"
            >
              {n.name}
            </text>
          </g>
        ))}
      </svg>
    </div>
  );
}
