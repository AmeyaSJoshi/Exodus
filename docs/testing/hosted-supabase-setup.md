# Hosted Supabase — minimal setup for physical iPhone testing

> **Steps 1–6 are DONE** for project `egress` (ref in `.env.hosted`, gitignored).
> Migrations pushed, demo data loaded, both profiles attached, dashboard wired.
> Remaining: sign in and point the phone at it (steps 7–8).
>
> Not verified by me: sign-in, realtime, and the block/clear loop against the
> hosted project — those need the account passwords, which I do not have.

The local stack binds its API to `127.0.0.1`, so a physical iPhone cannot reach
it. A free hosted project is the shortest path to testing on a real device.

Everything below is the same schema, seed and code already verified locally —
only the URL and anon key change.

## 1. Create the project

<https://supabase.com/dashboard> → **New project**.

- Name: `egress`
- Database password: generate one and save it in your password manager
- Region: closest to you

Wait for provisioning (~2 minutes).

## 2. Link this repo to it

From the repo root:

```bash
npx supabase login          # opens a browser, generates an access token
npx supabase link --project-ref <YOUR-PROJECT-REF>
```

The project ref is in the dashboard URL:
`https://supabase.com/dashboard/project/<YOUR-PROJECT-REF>`.

You will be asked for the database password from step 1.

## 3. Push the schema

```bash
npx supabase db push
```

This applies the four migrations. It does **not** run `seed.sql`.

## 4. Create users and demo data

`seed.sql` writes directly into `auth.users`, which is fine locally but is not
how you should create users on a hosted project. Instead:

**a. Create the three users** in Dashboard → **Authentication → Users → Add user**
(tick *Auto Confirm User*):

| Email | Password |
|---|---|
| `admin@egress.test` | pick your own |
| `viewer@egress.test` | pick your own |

(`outsider@egress.test` is only needed to re-run the isolation checks.)

**b. Run the demo data.** A hosted-safe copy is generated from `seed.sql` with
the `auth.users` writes stripped:

```bash
npx supabase db query --linked --file /tmp/hosted_seed.sql
```

Note `--linked`; without it the CLI silently targets your *local* database.

**c. Attach the profiles** — no need to look up UUIDs by hand; match on email:

```bash
npx supabase db query --linked "
insert into public.profiles (id, organization_id, role, display_name)
select u.id, '11111111-1111-1111-1111-111111111111'::uuid,
       case when u.email='admin@egress.test' then 'admin' else 'viewer' end,
       case when u.email='admin@egress.test' then 'Admin' else 'Occupant' end
from auth.users u where u.email in ('admin@egress.test','viewer@egress.test')
on conflict (id) do update
  set organization_id = excluded.organization_id, role = excluded.role;"
```

Without a `profiles` row a user can see nothing — `current_org_id()` returns
null and every policy denies. That is the intended default.

## 5. Get the keys

Dashboard → **Project Settings → API**:

- **Project URL** → `https://<ref>.supabase.co`
- **publishable key** (`sb_publishable_…`, the current name for the anon key) →
  safe for the phone and the browser; RLS constrains it
- **service_role key** → never put this in the app, the dashboard, or git

## 6. Point the dashboard at it

```bash
# dashboard/.env.local
NEXT_PUBLIC_SUPABASE_URL=https://<ref>.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<anon key>
```

```bash
cd dashboard && npm run dev
```

## 7. Point the iPhone at it

Build to the device (Xcode → select your iPhone → ▶︎), then in the app:

**Configure → Live Backend Demo**, and fill in:

- Backend URL: `https://<ref>.supabase.co`
- Anon key: paste the anon key
- Email / password: `viewer@egress.test` and the password you chose

The URL is HTTPS, so no App Transport Security exception is involved — the
local-HTTP exception in `Info.plist` stays scoped to `localhost` / `127.0.0.1`
and is unused here.

Typing the anon key on a phone is tedious; paste it from Notes or a password
manager, or AirDrop it to yourself.

## 8. Verify

Repeat the demo from `live-rerouting-demo.md`: block the stairwell on the
dashboard, watch the phone reroute, clear it, watch the route return.

To re-run the security checks against the hosted project:

```bash
psql "$(npx supabase status --output json | python3 -c 'import sys,json;print(json.load(sys.stdin)["DB_URL"])')" \
  -v ON_ERROR_STOP=1 -f supabase/verification/security_checks.sql
```

or paste the file into the SQL Editor. It needs all three test users to exist.

## Cost and cleanup

The free tier is enough for this. Projects pause after a week of inactivity —
opening the dashboard resumes them. Delete the project when you are done:
Settings → General → Delete project.
