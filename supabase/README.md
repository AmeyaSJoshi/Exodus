# EGRESS Supabase backend

## Layout

- `migrations/` — schema, RLS, and RPCs. Applied in filename order.
- `seed.sql` — demo organization, building and published map.
- `tests/security_checks.sql` — assertions that unauthorized writes fail.

## Local setup

```bash
supabase start
supabase db reset            # applies migrations + seed
```

Create three users in Studio → Authentication (any password):

| Email | Role after seed | Purpose |
|---|---|---|
| `admin@egress.test` | admin, org A | dashboard login |
| `viewer@egress.test` | viewer, org A | occupant / iPhone |
| `outsider@egress.test` | admin, org B | proves tenant isolation |

Then re-run `supabase db reset` so the seed attaches their profiles, and verify:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/security_checks.sql
```

## Identity model

`id` is a per-row primary key. **`stable_id` is the UUID the iPhone assigned**
when the zone was mapped, and is what survives across map versions. Live state
references `stable_id`, so blocking a stairwell is not undone by republishing
the map.

## Revisions

A single global sequence stamps `revision` on every live-state write. Clients
keep one integer watermark and discard any event at or below it.
