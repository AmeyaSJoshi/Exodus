-- Security verification. Run against a local Supabase after `supabase db reset`
-- Prerequisite: `npx supabase db reset` (the seed creates the three test users).
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/security_checks.sql
--
-- Test users are created by seed.sql, so `supabase db reset` alone is enough.
-- Every check RAISES on failure, so a clean run means all assertions held.
-- These impersonate users the way PostgREST does: role `authenticated` plus a
-- request JWT claim carrying the user id.

\set QUIET on
set client_min_messages = warning;

create or replace function pg_temp.act_as(p_email text)
returns void
language plpgsql
as $$
declare
    uid uuid;
begin
    select id into uid from auth.users where email = p_email;
    if uid is null then
        raise exception 'Test user % does not exist — create it before running these checks', p_email;
    end if;
    execute format('set local role authenticated');
    execute format('set local request.jwt.claims = %L', json_build_object('sub', uid, 'role', 'authenticated')::text);
end;
$$;

create or replace function pg_temp.assert(p_condition boolean, p_label text)
returns void
language plpgsql
as $$
begin
    if not p_condition then
        raise exception 'FAILED: %', p_label;
    end if;
    raise notice 'ok: %', p_label;
end;
$$;

-- MARK: 1. Occupant cannot write building-wide live state ---------------------

do $$
declare
    bldg uuid := '33333333-3333-3333-3333-333333333333';
    edge uuid := 'b0000000-0000-0000-0000-000000000002';
    blocked boolean := false;
begin
    perform pg_temp.act_as('viewer@egress.test');
    begin
        insert into public.live_edge_states (building_id, edge_stable_id, status)
        values (bldg, edge, 'blocked');
    exception when insufficient_privilege or others then
        blocked := true;
    end;
    perform pg_temp.assert(blocked, 'occupant direct insert into live_edge_states is rejected');
end $$;
reset role;

do $$
declare
    bldg uuid := '33333333-3333-3333-3333-333333333333';
    edge uuid := 'b0000000-0000-0000-0000-000000000002';
    blocked boolean := false;
begin
    perform pg_temp.act_as('viewer@egress.test');
    begin
        perform public.set_edge_state(bldg, edge, 'blocked', 'blockedHallway', 'test', 5, null);
    exception when others then
        blocked := true;
    end;
    perform pg_temp.assert(blocked, 'occupant set_edge_state RPC is rejected');
end $$;
reset role;

-- MARK: 2. Admin can write, and the revision advances -------------------------

do $$
declare
    bldg uuid := '33333333-3333-3333-3333-333333333333';
    edge uuid := 'b0000000-0000-0000-0000-000000000002';
    r1 bigint;
    r2 bigint;
begin
    perform pg_temp.act_as('admin@egress.test');
    select revision into r1 from public.set_edge_state(bldg, edge, 'blocked', 'blockedHallway', 'Debris', 5, null);
    select revision into r2 from public.set_edge_state(bldg, edge, 'available', null, null, 1, null);
    perform pg_temp.assert(r1 is not null and r2 > r1, 'revision increases monotonically on update');
end $$;
reset role;

-- MARK: 3. Cross-organization isolation ---------------------------------------

do $$
declare
    bldg uuid := '33333333-3333-3333-3333-333333333333';
    visible integer;
begin
    perform pg_temp.act_as('outsider@egress.test');
    select count(*) into visible from public.buildings where id = bldg;
    perform pg_temp.assert(visible = 0, 'other org cannot see this building');

    select count(*) into visible from public.live_edge_states where building_id = bldg;
    perform pg_temp.assert(visible = 0, 'other org cannot read live state');

    select count(*) into visible from public.route_nodes;
    perform pg_temp.assert(visible = 0, 'other org cannot read the graph');
end $$;
reset role;

do $$
declare
    bldg uuid := '33333333-3333-3333-3333-333333333333';
    edge uuid := 'b0000000-0000-0000-0000-000000000002';
    blocked boolean := false;
begin
    -- An admin, but of a different organization.
    perform pg_temp.act_as('outsider@egress.test');
    begin
        perform public.set_edge_state(bldg, edge, 'blocked', null, null, 3, null);
    exception when others then
        blocked := true;
    end;
    perform pg_temp.assert(blocked, 'admin of another org cannot change this building');
end $$;
reset role;

-- MARK: 4. Occupant reports ---------------------------------------------------

do $$
declare
    bldg uuid := '33333333-3333-3333-3333-333333333333';
    edge uuid := 'b0000000-0000-0000-0000-000000000002';
    uid uuid;
    inserted integer;
    spoofed boolean := false;
begin
    select id into uid from auth.users where email = 'viewer@egress.test';
    perform pg_temp.act_as('viewer@egress.test');

    insert into public.user_reports (building_id, edge_stable_id, reporter_id, report_type, description)
    values (bldg, edge, uid, 'blockedHallway', 'Debris in the corridor');
    get diagnostics inserted = row_count;
    perform pg_temp.assert(inserted = 1, 'occupant can file a report');

    -- Reporting as somebody else must fail.
    begin
        insert into public.user_reports (building_id, edge_stable_id, reporter_id, report_type)
        values (bldg, edge, gen_random_uuid(), 'smoke');
    exception when others then
        spoofed := true;
    end;
    perform pg_temp.assert(spoofed, 'occupant cannot file a report as another user');
end $$;
reset role;

do $$
declare
    updated integer;
    denied boolean := false;
    rid uuid;
begin
    select id into rid from public.user_reports order by created_at desc limit 1;
    perform pg_temp.act_as('viewer@egress.test');
    begin
        update public.user_reports set status = 'verified' where id = rid;
        get diagnostics updated = row_count;
        denied := (updated = 0);
    exception when others then
        denied := true;
    end;
    perform pg_temp.assert(denied, 'occupant cannot verify their own report');
end $$;
reset role;

-- MARK: 5. Verification promotes a report to live state ------------------------

do $$
declare
    rid uuid;
    st text;
    live text;
    edge uuid;
begin
    select id, edge_stable_id into rid, edge
    from public.user_reports where status = 'pending' order by created_at desc limit 1;

    perform pg_temp.act_as('admin@egress.test');
    select status into st from public.review_report(rid, 'verified', 'blockedHallway', 'Confirmed', 5);
    perform pg_temp.assert(st = 'verified', 'admin can verify a report');

    select status into live from public.live_edge_states where edge_stable_id = edge;
    perform pg_temp.assert(live = 'blocked', 'verification creates building-wide live state');

    perform public.clear_edge_state('33333333-3333-3333-3333-333333333333', edge);
end $$;
reset role;

-- MARK: 6. Published maps are immutable ----------------------------------------

do $$
declare
    mapv uuid := '44444444-4444-4444-4444-444444444444';
    blocked boolean := false;
begin
    perform pg_temp.act_as('admin@egress.test');
    begin
        insert into public.route_nodes (map_version_id, stable_id, name, type, position)
        values (mapv, gen_random_uuid(), 'Sneaky Node', 'room', '{"x":0,"y":0,"z":0}');
    exception when others then
        blocked := true;
    end;
    perform pg_temp.assert(blocked, 'nodes cannot be added to a published map version');
end $$;
reset role;

-- MARK: 7. Live state must reference the active map ----------------------------

do $$
declare
    bldg uuid := '33333333-3333-3333-3333-333333333333';
    blocked boolean := false;
begin
    perform pg_temp.act_as('admin@egress.test');
    begin
        perform public.set_edge_state(bldg, gen_random_uuid(), 'blocked', null, null, 3, null);
    exception when others then
        blocked := true;
    end;
    perform pg_temp.assert(blocked, 'live state for an unknown edge is rejected');
end $$;
reset role;

-- MARK: 8. Snapshot respects expiry --------------------------------------------

do $$
declare
    bldg uuid := '33333333-3333-3333-3333-333333333333';
    edge uuid := 'b0000000-0000-0000-0000-000000000002';
    snap jsonb;
    st text;
begin
    perform pg_temp.act_as('admin@egress.test');
    perform public.set_edge_state(bldg, edge, 'blocked', 'smoke', 'expired test', 3, now() - interval '1 minute');
    snap := public.building_state_snapshot(bldg);

    select value ->> 'status' into st
    from jsonb_array_elements(snap -> 'edges') value
    where value ->> 'edge_stable_id' = edge::text;

    perform pg_temp.assert(st = 'available', 'expired live state reads as available in the snapshot');
    perform public.clear_edge_state(bldg, edge);
end $$;
reset role;

-- MARK: 9. Audit trail ----------------------------------------------------------

do $$
declare
    entries integer;
    denied boolean := false;
begin
    perform pg_temp.act_as('admin@egress.test');
    select count(*) into entries from public.live_state_audit;
    perform pg_temp.assert(entries > 0, 'administrator actions are recorded in the audit log');

    begin
        delete from public.live_state_audit;
        denied := (not found);
    exception when others then
        denied := true;
    end;
    perform pg_temp.assert(denied, 'audit log cannot be deleted from a client');
end $$;
reset role;

-- MARK: 10. Anonymous access ---------------------------------------------------
-- The `anon` role is what an unauthenticated client presents. No policy grants
-- it anything, so every table must read as empty and every write must fail.

do $$
declare
    bldg uuid := '33333333-3333-3333-3333-333333333333';
    edge uuid := 'b0000000-0000-0000-0000-000000000002';
    visible integer;
    denied boolean := false;
begin
    set local role anon;
    set local request.jwt.claims = '{"role":"anon"}';

    select count(*) into visible from public.buildings;
    perform pg_temp.assert(visible = 0, 'anonymous cannot read buildings');

    select count(*) into visible from public.route_nodes;
    perform pg_temp.assert(visible = 0, 'anonymous cannot read the graph');

    select count(*) into visible from public.live_edge_states;
    perform pg_temp.assert(visible = 0, 'anonymous cannot read live state');

    select count(*) into visible from public.user_reports;
    perform pg_temp.assert(visible = 0, 'anonymous cannot read reports');

    begin
        insert into public.user_reports (building_id, edge_stable_id, report_type)
        values (bldg, edge, 'smoke');
    exception when others then
        denied := true;
    end;
    perform pg_temp.assert(denied, 'anonymous cannot file a report');
end $$;
reset role;

do $$
declare
    bldg uuid := '33333333-3333-3333-3333-333333333333';
    edge uuid := 'b0000000-0000-0000-0000-000000000002';
    denied boolean := false;
begin
    set local role anon;
    set local request.jwt.claims = '{"role":"anon"}';
    begin
        perform public.set_edge_state(bldg, edge, 'blocked', null, null, 3, null);
    exception when others then
        denied := true;
    end;
    perform pg_temp.assert(denied, 'anonymous cannot change live state');
end $$;
reset role;

-- MARK: 11. Occupant can read what they should ---------------------------------

do $$
declare
    bldg uuid := '33333333-3333-3333-3333-333333333333';
    visible integer;
    denied boolean := false;
begin
    perform pg_temp.act_as('viewer@egress.test');

    select count(*) into visible from public.buildings where id = bldg;
    perform pg_temp.assert(visible = 1, 'occupant can read their own building');

    select count(*) into visible from public.route_nodes;
    perform pg_temp.assert(visible = 7, 'occupant can read the published graph nodes');

    select count(*) into visible from public.route_edges;
    perform pg_temp.assert(visible = 6, 'occupant can read the published graph edges');

    perform public.building_state_snapshot(bldg);
    perform pg_temp.assert(true, 'occupant can fetch a building state snapshot');

    begin
        perform public.publish_map_version('44444444-4444-4444-4444-444444444444');
    exception when others then
        denied := true;
    end;
    perform pg_temp.assert(denied, 'occupant cannot publish a map version');
end $$;
reset role;

\echo 'All security checks passed.'
