import { NextResponse } from "next/server";

// Server-only proxy to Nominatim (OpenStreetMap). No API key — the dashboard
// client posts an address here and gets back coordinates, nothing else.

const GEOCODE_URL = "https://nominatim.openstreetmap.org/search";
const USER_AGENT = "EGRESS/1.0 (dev)";
const MIN_INTERVAL_MS = 1000; // Nominatim usage policy: max 1 request/sec.

// Simple in-memory queue: each call awaits the previous one, then waits out
// whatever's left of the 1s window before firing its own request.
let queue: Promise<void> = Promise.resolve();
let lastRequestAt = 0;

function throttle(): Promise<void> {
  const run = queue.then(async () => {
    const wait = Math.max(0, lastRequestAt + MIN_INTERVAL_MS - Date.now());
    if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
    lastRequestAt = Date.now();
  });
  queue = run.catch(() => {});
  return run;
}

export async function POST(request: Request) {
  let address: unknown;
  try {
    ({ address } = await request.json());
  } catch {
    return NextResponse.json({ error: "Request body must be JSON." }, { status: 400 });
  }
  if (typeof address !== "string" || !address.trim()) {
    return NextResponse.json({ error: "An address is required." }, { status: 400 });
  }

  const url = new URL(GEOCODE_URL);
  url.searchParams.set("q", address);
  url.searchParams.set("format", "json");
  url.searchParams.set("limit", "1");

  await throttle();
  const upstream = await fetch(url, { headers: { "User-Agent": USER_AGENT } });
  const data = await upstream.json();

  if (!Array.isArray(data) || !data.length) {
    return NextResponse.json({ error: "No match for that address." }, { status: 422 });
  }

  const result = data[0];
  return NextResponse.json({
    lat: Number(result.lat),
    lng: Number(result.lon),
    formatted_address: result.display_name,
  });
}
