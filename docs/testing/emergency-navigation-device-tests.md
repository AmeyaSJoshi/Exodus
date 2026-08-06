# EGRESS — Physical Device Test Checklist

ARKit does not run in the Simulator. Nothing below can be verified by automated
tests; every item requires a physical non-LiDAR iPhone in a real mapped space.

## Milestone 1 (available now)

- [ ] App launches; Home shows **Emergency**, **Configure**, **Saved Maps**
- [ ] Emergency is disabled with an explanation when no zones exist
- [ ] Configure → Map a New Zone still records a hallway (existing flow intact)
- [ ] Saved Maps still lists, renames and deletes zones
- [ ] Opening a zone saved *before* this milestone still loads (graph migration)
- [ ] Zone detail shows a non-zero "Graph: N nodes · M edges" row
- [ ] Accessibility toggles change the computed route summary
- [ ] Existing AR navigation still runs end to end

## Milestone 2 (available now)

- [ ] Map and save a hallway
- [ ] Terminate and reopen the app
- [ ] Select "I Don't Know Where I Am"
- [ ] Relocalize from the original viewpoint
- [ ] Relocalize from a slightly different viewpoint
- [ ] Relocalize under different lighting
- [ ] Estimate location while standing at a waypoint
- [ ] Estimate location halfway along a hallway
- [ ] Reject an estimate when too far from the recorded route
- [ ] Manual fallback (choose room / tap map) is always reachable

## Milestone 3 (available now)

- [ ] Automatically choose an exit
- [ ] Enable avoid-stairs mode
- [ ] Confirm the route changes
- [ ] Alternative exits are listed

## Milestone 4 (available now)

- [ ] Block the route ahead
- [ ] Verify AR arrows change
- [ ] Verify **old** AR arrows are fully removed before the new ones appear
- [ ] Clear the hazard and confirm the original route returns
- [ ] Report "Smoke ahead" and confirm the route avoids it without hard-blocking
- [ ] Use "Select a Different Segment" and confirm the right segment is blocked
- [ ] Block every path and confirm an honest failure, not a wrong route
- [ ] Configure -> Active Hazards lists the report and clears it

## Milestone 5 (not yet built)

- [ ] Confirm a detected room sign
- [ ] Voice report blocks the correct segment after confirmation
- [ ] Lose tracking by pointing at a blank surface
- [ ] Verify precise AR arrows disappear
- [ ] Successfully relocalize and resume
- [ ] Complete the route and receive destination feedback

## Diagnostics

Enable the collapsed **Diagnostics** panel (debug builds) during any test and
use **Export Log** to share the trace when reporting a failure.
