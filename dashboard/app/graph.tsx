"use client";

import { useMemo } from "react";
import type { LiveEdgeState, RouteEdge, RouteNode } from "@/lib/supabase";
import { hazardIcon, nodeMeta } from "@/lib/model";

const W = 900;
const H = 560;
const PAD = 56;

/**
 * Top-down floor plan built from the stored node positions (X/Z plane).
 *
 * Status is carried by line style and a badge as well as colour: blocked edges
 * are dashed with a hazard glyph on them, restricted are dotted. Someone who
 * cannot separate red from grey still sees which segments are out.
 */
export function GraphView({
  nodes,
  edges,
  nodeByStable,
  live,
  selected,
  onSelect,
}: {
  nodes: RouteNode[];
  edges: RouteEdge[];
  nodeByStable: Record<string, RouteNode>;
  live: Record<string, LiveEdgeState>;
  selected: RouteEdge | null;
  onSelect: (e: RouteEdge | null) => void;
}) {
  const geometry = useMemo(() => {
    if (!nodes.length) return null;
    const xs = nodes.map((n) => n.position.x);
    const zs = nodes.map((n) => n.position.z);
    const minX = Math.min(...xs);
    const maxX = Math.max(...xs);
    const minZ = Math.min(...zs);
    const maxZ = Math.max(...zs);
    const scale = Math.min((W - PAD * 2) / (maxX - minX || 1), (H - PAD * 2) / (maxZ - minZ || 1));
    // Centre the plan rather than pinning it to the top-left, which left a
    // lopsided gap on any floor that is wider than it is deep.
    const offsetX = (W - (maxX - minX) * scale) / 2;
    const offsetZ = (H - (maxZ - minZ) * scale) / 2;
    return {
      px: (x: number) => offsetX + (x - minX) * scale,
      pz: (z: number) => offsetZ + (z - minZ) * scale,
    };
  }, [nodes]);

  // Captions collide on floors where rooms sit a few metres apart. Each label
  // takes the first free slot above or below its node.
  const labelOffsets = useMemo(() => {
    if (!geometry) return {};
    const placed: { x1: number; y1: number; x2: number; y2: number }[] = [];
    const out: Record<string, number> = {};
    for (const n of nodes) {
      const cx = geometry.px(n.position.x);
      const cy = geometry.pz(n.position.z);
      const halfWidth = Math.max(18, n.name.length * 3.4);
      for (const dy of [-16, 22, -28, 34, -40, 46]) {
        const box = { x1: cx - halfWidth, y1: cy + dy - 8, x2: cx + halfWidth, y2: cy + dy + 8 };
        const clash = placed.some(
          (p) => !(box.x2 < p.x1 || box.x1 > p.x2 || box.y2 < p.y1 || box.y1 > p.y2),
        );
        if (!clash) {
          placed.push(box);
          out[n.stable_id] = dy;
          break;
        }
      }
      if (out[n.stable_id] === undefined) out[n.stable_id] = -16;
    }
    return out;
  }, [nodes, geometry]);

  if (!nodes.length || !geometry) {
    return (
      <div className="flex h-[420px] flex-col items-center justify-center gap-2 rounded-xl border border-hairline bg-surface p-8 text-center">
        <p className="text-lg font-semibold">No published map</p>
        <p className="max-w-sm text-sm text-ink-2">
          Map a zone on an iPhone and publish it to this building. The floor plan and its
          incident controls appear here once a map version is live.
        </p>
      </div>
    );
  }

  const { px, pz } = geometry;

  return (
    <div className="rounded-xl border border-hairline bg-surface">
      <svg
        viewBox={`0 0 ${W} ${H}`}
        className="h-auto w-full"
        role="img"
        aria-label="Floor plan with route segments and active incidents"
        onClick={() => onSelect(null)}
      >
        {edges.map((e) => {
          const a = nodeByStable[e.from_node_stable_id];
          const b = nodeByStable[e.to_node_stable_id];
          if (!a || !b) return null;
          const state = live[e.stable_id];
          const status = state?.status ?? "available";
          const isSel = selected?.stable_id === e.stable_id;
          const x1 = px(a.position.x);
          const y1 = pz(a.position.z);
          const x2 = px(b.position.x);
          const y2 = pz(b.position.z);
          const mx = (x1 + x2) / 2;
          const my = (y1 + y2) / 2;

          const stroke =
            status === "blocked" ? "#de1c18" : status === "restricted" ? "#f2a32a" : "#3d434e";
          const dash =
            status === "blocked" ? "10 7" : status === "restricted" ? "3 6" : undefined;

          return (
            <g
              key={e.stable_id}
              className="cursor-pointer"
              onClick={(ev) => {
                ev.stopPropagation();
                onSelect(e);
              }}
            >
              {isSel && (
                <line x1={x1} y1={y1} x2={x2} y2={y2} stroke="#3f8cff" strokeWidth={14} strokeOpacity={0.35} strokeLinecap="round" />
              )}
              <line
                x1={x1}
                y1={y1}
                x2={x2}
                y2={y2}
                stroke={stroke}
                strokeWidth={status === "available" ? 5 : 6}
                strokeDasharray={dash}
                strokeLinecap="round"
              />
              {status !== "available" && (
                <>
                  <circle cx={mx} cy={my} r={11} fill="#0d0e11" stroke={stroke} strokeWidth={2} />
                  <text x={mx} y={my + 4} textAnchor="middle" fontSize="11">
                    {hazardIcon(state?.hazard_type)}
                  </text>
                </>
              )}
              {/* Wider invisible hit area so thin lines stay clickable. */}
              <line x1={x1} y1={y1} x2={x2} y2={y2} stroke="transparent" strokeWidth={22} />
            </g>
          );
        })}

        {nodes.map((n) => {
          const meta = nodeMeta(n.type);
          const cx = px(n.position.x);
          const cy = pz(n.position.z);
          const r = meta.r;
          return (
            <g key={n.stable_id}>
              {meta.shape === "circle" && <circle cx={cx} cy={cy} r={r} fill={meta.color} />}
              {meta.shape === "square" && (
                <rect x={cx - r} y={cy - r} width={r * 2} height={r * 2} rx={2} fill={meta.color} />
              )}
              {meta.shape === "diamond" && (
                <rect
                  x={cx - r} y={cy - r} width={r * 2} height={r * 2}
                  fill={meta.color} transform={`rotate(45 ${cx} ${cy})`}
                />
              )}
              {meta.shape === "triangle" && (
                <polygon
                  points={`${cx},${cy - r - 2} ${cx + r + 1},${cy + r} ${cx - r - 1},${cy + r}`}
                  fill={meta.color}
                />
              )}
              {n.type !== "hallwayPoint" && (
                <text
                  x={cx}
                  y={cy + (labelOffsets[n.stable_id] ?? -16)}
                  textAnchor="middle"
                  fontSize="12"
                  fill="#e6e8ec"
                  className="map-label select-none"
                >
                  {n.name}
                </text>
              )}
            </g>
          );
        })}
      </svg>

      <Legend />
    </div>
  );
}

function Legend() {
  const items = [
    { key: "exit", label: "Exit" },
    { key: "stairwell", label: "Stairwell" },
    { key: "elevator", label: "Elevator" },
    { key: "room", label: "Room" },
    { key: "intersection", label: "Intersection" },
    { key: "refugeArea", label: "Refuge" },
  ];
  return (
    <div className="flex flex-wrap items-center gap-x-5 gap-y-2 border-t border-hairline px-4 py-3 text-xs text-ink-2">
      {items.map((i) => {
        const meta = nodeMeta(i.key);
        return (
          <span key={i.key} className="flex items-center gap-1.5">
            <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden>
              {meta.shape === "circle" && <circle cx="6" cy="6" r="5" fill={meta.color} />}
              {meta.shape === "square" && <rect x="1" y="1" width="10" height="10" rx="2" fill={meta.color} />}
              {meta.shape === "diamond" && <rect x="2" y="2" width="8" height="8" fill={meta.color} transform="rotate(45 6 6)" />}
              {meta.shape === "triangle" && <polygon points="6,0 12,11 0,11" fill={meta.color} />}
            </svg>
            {i.label}
          </span>
        );
      })}
      <span className="flex items-center gap-1.5">
        <svg width="26" height="8" viewBox="0 0 26 8" aria-hidden>
          <line x1="1" y1="4" x2="25" y2="4" stroke="#de1c18" strokeWidth="3" strokeDasharray="7 5" />
        </svg>
        Blocked
      </span>
      <span className="flex items-center gap-1.5">
        <svg width="26" height="8" viewBox="0 0 26 8" aria-hidden>
          <line x1="1" y1="4" x2="25" y2="4" stroke="#f2a32a" strokeWidth="3" strokeDasharray="2 4" />
        </svg>
        Restricted
      </span>
    </div>
  );
}
