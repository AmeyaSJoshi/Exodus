# Live Rerouting Demo — runbook

Verified end to end on 2026-08-06 (Simulator + local Supabase + dashboard).

## One-time setup

```bash
cd "/Users/ameyajoshi/Claude + Codex Projects/Vector"
npm install                 # repo-local Supabase CLI
cd dashboard && npm install && cd ..
```

Create `dashboard/.env.local` from the running stack:

```bash
npx supabase start
npx supabase status         # copy ANON_KEY
cp dashboard/.env.example dashboard/.env.local
# paste ANON_KEY into NEXT_PUBLIC_SUPABASE_ANON_KEY
```

## Run the demo

**1. Backend**

```bash
npx supabase start
npx supabase db reset       # migrations + seed (creates the test users)
```

**2. Dashboard**

```bash
cd dashboard && npm run dev
```

Open <http://localhost:3000> and sign in:

| Field | Value |
|---|---|
| Email | `admin@egress.test` |
| Password | `egress-admin-pw` |

You should see **Wade Academic Center**, its 7 nodes and 6 edges, `Realtime: live`
and a revision number.

**3. iPhone Simulator**

```bash
cd EgressMapper
xcodegen generate
xcodebuild build -project EgressMapper.xcodeproj -scheme EgressMapper \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

Install, then launch with the backend injected (avoids typing a JWT by hand):

```bash
UDID=$(xcrun simctl list devices | grep -m1 "iPhone 17 Pro (" | grep -oE "[0-9A-F-]{36}")
APP=$(xcodebuild -project EgressMapper.xcodeproj -scheme EgressMapper \
  -destination "platform=iOS Simulator,id=$UDID" -showBuildSettings 2>/dev/null \
  | grep -m1 " BUILT_PRODUCTS_DIR" | sed 's/.*= //')/EgressMapper.app
KEY=$(cd .. && npx supabase status 2>/dev/null \
  | python3 -c "import sys,json;print(json.loads([l for l in sys.stdin if l.startswith('{')][0])['ANON_KEY'])")

xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" com.egress.mapper \
  -egress.backend.url "http://127.0.0.1:54321" \
  -egress.backend.anonKey "$KEY"
```

**4. In the app**

1. Tap **Configure**
2. Tap **Live Backend Demo**
3. Tap **Sign in as occupant** (email/password are pre-filled with
   `viewer@egress.test` / `egress-viewer-pw`)

Expect: **Live** with a green dot, a revision number, `Wade Academic Center`
selected, start `Room 214`, and the route
**East Exit — 24 m · Room 214 → Central Intersection → East Stairwell → East Exit**.

## The demonstration

| Step | Where | Action | Expected |
|---|---|---|---|
| 1 | Dashboard | Click the red **Block Central Intersection → East Stairwell** button | Edge turns dashed red; revision increases |
| 2 | Simulator | *(do nothing)* | Banner: "Central Intersection → East Stairwell was blocked by an administrator. Rerouting to West Exit." Route becomes **West Exit — 50 m · Room 214 → Central Intersection → Elevator → West Exit**. Revision matches the dashboard. |
| 3 | Dashboard | Click the green **Clear** button | Edge returns to solid grey |
| 4 | Simulator | *(do nothing)* | Banner: "Central Intersection → East Stairwell is open again." Route returns to **East Exit — 24 m**. |

Neither app is restarted at any point.

Instead of the demo button you can click any line on the dashboard map and use
**Block** / **Clear** in the right-hand panel, optionally with a reason.

## Also worth trying

- **Accessibility interaction** — in the app turn on *Wheelchair accessible only*.
  The route moves to West Exit via the elevator. Now block the elevator segment
  from the dashboard: the app reports that no accessible route exists rather than
  silently routing you down the stairs.
- **Offline** — stop the backend (`npx supabase stop`), force-quit and relaunch
  the app. It loads the cached graph and last known state, and says
  "Using cached data — live updates unavailable".

## Verified results

```
admin login (GoTrue)                OK
occupant login (GoTrue)             OK
occupant reads published graph      OK (7 nodes / 6 edges)
occupant blocked from writing state OK (rejected)
cross-org admin blocked             OK (rejected)
anonymous access                    OK (rejected)
dashboard build                     OK
iOS build                           OK
iOS tests                           198 passed
realtime subscribe                  SUBSCRIBED
block   -> rev 19 -> 21, route East Exit -> West Exit   OK
clear   -> rev 23,      route West Exit -> East Exit    OK
permanent graph rows changed        0
```

## Two-device test (verified)

Boot a second simulator and launch the app on both:

```bash
U1=$(xcrun simctl list devices | grep -m1 "iPhone 17 Pro (" | grep -oE "[0-9A-F-]{36}")
U2=$(xcrun simctl list devices | grep -m1 "iPhone 17 ("     | grep -oE "[0-9A-F-]{36}")
for U in $U1 $U2; do
  xcrun simctl boot "$U" 2>/dev/null
  xcrun simctl install "$U" "$APP"
  xcrun simctl launch  "$U" com.egress.mapper \
    -egress.backend.url "http://127.0.0.1:54321" -egress.backend.anonKey "$KEY"
done
```

Sign both in, then turn on **Wheelchair accessible only** on the second device
and block the stairwell from the dashboard.

| | Profile | Before | After block (both rev 25) |
|---|---|---|---|
| Device 1 | Standard | East Exit, 24 m via stairwell | "…blocked by an administrator. **Rerouting to West Exit**" — 50 m |
| Device 2 | Wheelchair | Already West Exit (stairs excluded) | "…changed. **Route unaffected.**" — stays West Exit |

Both received the same event at the same revision and each decided locally what
it meant for *its own* route. Clearing (rev 27) returned device 1 to East Exit
and correctly left device 2 alone.

## Not yet verified
- **Physical iPhone.** Blocked: the Supabase CLI binds its API to `127.0.0.1`
  only, so `http://<mac-lan-ip>:54321` is refused (verified: `curl` to the LAN
  address returns no response). A physical phone therefore needs a TCP forwarder
  on the Mac, an SSH reverse tunnel, or a hosted Supabase project. The app side
  is ready — the backend URL field accepts any host and ATS already permits
  local HTTP.
- **AR arrows reacting to a live block.** The code path exists — `GuidanceView`
  now takes a `liveService` and subscribes when the zone has been published, and
  a live block goes through the same reroute that tears down old anchors. It has
  not been run on a device, because AR navigation needs a saved `ARWorldMap`,
  which the seeded demo building does not have. To try it: map a zone, publish it
  (below), then start AR navigation and block a segment from the dashboard.
- **Map publish from the phone.** Implemented (Saved Maps -> a zone ->
  **Publish Building Map**): validates the graph, creates a draft, uploads nodes
  and edges preserving their UUIDs, then calls `publish_map_version`. Not yet
  exercised end to end.
