# Map packages — what is verified, and what needs an iPhone

Three levels of verification, kept separate on purpose.

## 1. Code, build and unit verification — done

- 282 iOS unit tests pass (`xcodebuild test`, iPhone 17 Pro simulator).
- 60 SQL security assertions pass against a freshly reset local database.
- iOS app builds; dashboard builds and typechecks.

Covered by unit tests, with no device involved:

| Requirement | Test |
| --- | --- |
| Manifest carries zone/node/edge stable UUIDs | `MapPackageManifestTests` |
| Room numbers, aliases, accessibility, floor ids, sizes, SHA-256 | `MapPackageManifestTests` |
| Dangling route references rejected before upload | `testDanglingEdgeIsRejectedBeforeAnythingUploads` |
| Every upload completes before the version is published | `testPublishUploadsEveryArtifactAndTheManifestBeforePublishing` |
| Interrupted upload leaves a draft and cleans up | `testInterruptedUploadLeavesTheVersionUnpublishedAndCleansUp` |
| An unauthorized uploader never publishes | `testUnauthorizedUploaderNeverPublishes` |
| A new version never overwrites an old one's objects | `testPublishingAnUpdateTargetsANewVersionAndLeavesOldPathsAlone` |
| Download verifies checksums and schema | `MapPackageDownloadTests` |
| Corrupt or interrupted update keeps the cached version | `testCorruptedDownloadDoesNotReplaceTheCachedVersion`, `testInterruptedDownloadKeepsThePreviousVersion` |
| Offline load from cache | `testCachedPackageLoadsOfflineWithNoSourceCalls` |
| Saved Maps merges without duplicate cards | `SavedMapsMergeTests` |
| Occupants get no write actions | `testAStudentNeverGetsAWriteAction` |
| Localization is confined to the selected building | `BuildingLocalizationTests` |
| Existing saved maps still load and publish | `ExistingMapCompatibilityTests` |

## 2. Simulator product-flow verification — done

Against local Supabase, signed in as the seeded `viewer@egress.test`:

1. Saved Maps showed **Wade Academic Center · v1 · 7 nodes · Download Required**,
   offering only *Download* and *View Building* — no edit or publish control,
   and no local draft belonging to the mapper.
2. *Download* → status became **Offline Available**; actions became
   *Use in Emergency*, *View Building*, *Remove Download*.
3. Emergency → the building → route calculated from the downloaded package:
   **Room 214 → Central Intersection → East Stairwell → East Exit, 24 m**.
4. Blocking `Central Intersection → East Stairwell` from the database rerouted
   the running screen to **West Exit, 50 m** (rev 41 → 43), with the blocked
   segment drawn dashed red.
5. Clearing it returned the route to **East Exit, 24 m** (rev 45).
6. Live Backend Diagnostics was never opened during any of this.
7. Configure → Buildings showed the occupant lock for the viewer account.

The seeded building was published before packages existed, so its downloaded
package is graph-only. The app correctly reported **0 AR zone(s)** and did not
offer camera localization for it.

## 3. Physical-device AR verification — NOT DONE

The simulator has no ARKit world tracking, so none of the following has been
proven. Each needs an iPhone and a real walk.

- Saving a real `ARWorldMap` and publishing it as an artifact.
- Downloading that artifact on a second device and relocalizing against it.
- Whether relocalization now succeeds from more than one direction (the
  multi-viewpoint change is the intended fix, and is unproven in the field).
- Room-sign OCR against published aliases in real lighting.
- AR arrows being removed and re-rendered on a live reroute.
- Whether the confidence thresholds in `LocationEstimate.Thresholds` are right
  for real relocalized poses.

### The device test

On an iPhone signed in as the administrator account:

1. Configure → Map a New Zone. Walk a hallway with at least one room and one
   exit waypoint. Save.
2. Open the zone from Saved Maps. Add two or three reference photographs from
   different directions before publishing.
3. Saved Maps → the zone → **Attach to Building** → create or pick a building →
   confirm the *Localization package* section reports an included AR world map
   and the expected number of reference views → **Publish**.
4. Confirm the result reports the uploaded file count.

Then on a second iPhone signed in as the occupant account:

5. Saved Maps → the building → **Download** → wait for **Offline Available**.
6. Emergency → the building → **I Don't Know Where I Am**.
7. Stand somewhere in the mapped area and sweep the camera. Confirm it
   relocalizes, names a plausible nearest point, and states its confidence.
8. Repeat from a different direction and from a spot the zone was *not*
   recorded from — the second should fail to a manual fallback rather than
   claiming a confident wrong position.
9. Confirm, start the evacuation, and check the AR arrows.
10. From the dashboard, block a segment on the active route. Confirm the stale
    arrows disappear, a new route renders, and the reroute is announced.
