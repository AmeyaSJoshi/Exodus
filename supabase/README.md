# EGRESS Supabase backend

> **Status: VERIFIED** on 2026-08-06 against Supabase CLI 2.111.0 with OrbStack.
> `db reset` applies all four migrations and the seed with no errors or warnings,
> and all 29 security assertions pass. Reproduced from a clean reset twice.

## Layout

- `config.toml` — local stack configuration (`project_id = "egress"`).
- `migrations/` — schema, RLS, and RPCs. Applied in filename order.
- `seed.sql` — demo org, building, published map **and the three test users**.
- `verification/security_checks.sql` — 29 assertions; raises on the first failure.
  Kept out of `supabase/tests/` because that directory is for pgTAP, and these
  are plain psql assertions — `supabase test db` would report a parse failure.

## Prerequisite: a container runtime

The Supabase CLI is pinned per-repo (`npm install --save-dev supabase`, 2.111.0)
and needs Docker or Podman. Verified with **OrbStack**:

```bash
brew install --cask orbstack     # or: brew install --cask docker
```

Launch it once so its daemon starts and `docker` is on your `PATH`.

## Reproducible setup — two commands

```bash
npx supabase start
npx supabase db reset
```

`db reset` drops the database, re-applies every migration, then runs `seed.sql`.

**The test users are created by the seed, not by hand.** This matters: `db reset`
destroys anything created manually in Studio, so a "create users, then reset"
procedure silently loses them. Because they live in the seed, the users are
recreated on every reset and the whole setup is reproducible from a clean state.

| Email | Password | Role | Purpose |
|---|---|---|---|
| `admin@egress.test` | `egress-admin-pw` | admin, org A | dashboard login |
| `viewer@egress.test` | `egress-viewer-pw` | viewer, org A | occupant / iPhone |
| `outsider@egress.test` | `egress-outsider-pw` | **admin**, org B | proves tenant isolation |

`outsider` is deliberately an *admin* — of a different organization. That proves
the role alone is not sufficient; the organization must match too.

These credentials are local-development throwaways for a database bound to
localhost. They are not secrets and must never be used anywhere else.

## Verification

```bash
npm run db:verify
```

which runs the checks through the stack's own psql, so a local `psql` install is
not required:

```bash
docker exec -i supabase_db_egress psql -U postgres -v ON_ERROR_STOP=1 \
  < supabase/verification/security_checks.sql
```

A clean run ends with `All security checks passed.` To see each assertion,
change `client_min_messages` to `notice` at the top of the file.

The checks cover:

1. Occupants cannot insert live state directly, or via the RPC.
2. Admin writes succeed and `revision` increases monotonically.
3. Another organization sees zero buildings, graph rows and live state.
4. An admin of another organization cannot write to this building.
5. Occupants can file reports, but not as another user, and cannot verify them.
6. Verifying a report promotes it to building-wide live state.
7. Published map versions are immutable.
8. Live state referencing an unknown edge is rejected.
9. Expired live state reads as `available` in the snapshot.
10. The audit log records admin actions and cannot be deleted by a client.
11. Anonymous (`anon`) reads are empty and anonymous writes fail.
12. Occupants can read the published graph and fetch a snapshot, but cannot publish.

### Verified denial reasons

Assertions that expect a refusal catch any exception, so the actual messages were
inspected to confirm each denial is the *right* one:

| Attempt | Refused by |
|---|---|
| Occupant calls `set_edge_state` | `Not authorised to change live state for this building` |
| Admin of another org calls it | same explicit check (org mismatch) |
| Occupant inserts into `live_edge_states` | `new row violates row-level security policy` |
| Anonymous reads `buildings` | `permission denied for table buildings` |

### pgTAP

There are no pgTAP tests; `npx supabase test db` reports `NOTESTS`.

## Identity model

`id` is a per-row primary key. **`stable_id` is the UUID the iPhone assigned**
when the zone was mapped, and is what survives across map versions. Live state
references `stable_id`, so blocking a stairwell is not undone by republishing
the map.

## Revisions

A single global sequence stamps `revision` on every live-state write. Clients
keep one integer watermark and discard any event at or below it.

## Grants

RLS decides *which rows* a role may touch; `GRANT` decides whether it may touch
the table at all, and migration-created tables get no default privileges. Without
`20260806000400_grants.sql` every policy is unreachable — the first verification
run failed with `permission denied for table buildings`. The failure was safe but
the API was unusable.

`anon` is granted nothing, so unauthenticated access is refused outright rather
than merely filtered to zero rows.

## Secrets

`.env.example` documents the split. The anon key is safe to ship (RLS constrains
it); the service-role key bypasses RLS and must stay server-side. It has no
`NEXT_PUBLIC_` prefix so Next.js cannot inline it into a client bundle.
