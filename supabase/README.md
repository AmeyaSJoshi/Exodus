# EGRESS Supabase backend

> **Status: NOT YET VERIFIED.** The migrations, seed and security checks have
> never been executed — this machine has no container runtime, so the local
> Supabase stack cannot start. See "Prerequisite" below. Do not treat the SQL as
> working until `db reset` and the security checks have both run green.

## Layout

- `config.toml` — local stack configuration (`project_id = "egress"`).
- `migrations/` — schema, RLS, and RPCs. Applied in filename order.
- `seed.sql` — demo org, building, published map **and the three test users**.
- `tests/security_checks.sql` — 29 assertions; raises on the first failure.

## Prerequisite: a container runtime

The Supabase CLI is pinned per-repo (`npm install --save-dev supabase`, currently
2.111.0) and needs Docker or Podman. This machine has neither.

**One manual step — pick either:**

```bash
brew install --cask orbstack     # lighter and faster on macOS; recommended
```

or

```bash
brew install --cask docker       # Docker Desktop
```

Both are large GUI applications. After installing, **launch the app once** so its
daemon starts and puts `docker` on your `PATH`, then continue below.

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
export DATABASE_URL='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/security_checks.sql
```

A clean run ends with `All security checks passed.` The checks cover:

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

If `psql` is not installed, use the one bundled with the stack:

```bash
docker exec -i supabase_db_egress psql -U postgres -v ON_ERROR_STOP=1 \
  < supabase/tests/security_checks.sql
```

## Identity model

`id` is a per-row primary key. **`stable_id` is the UUID the iPhone assigned**
when the zone was mapped, and is what survives across map versions. Live state
references `stable_id`, so blocking a stairwell is not undone by republishing
the map.

## Revisions

A single global sequence stamps `revision` on every live-state write. Clients
keep one integer watermark and discard any event at or below it.

## Secrets

`.env.example` documents the split. The anon key is safe to ship (RLS constrains
it); the service-role key bypasses RLS and must stay server-side. It has no
`NEXT_PUBLIC_` prefix so Next.js cannot inline it into a client bundle.
