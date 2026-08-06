-- Demo data for local development.
--
-- Auth users must exist first. With the Supabase CLI running locally:
--   supabase start
--   # create the three users below via the Studio Auth tab or the admin API,
--   # then run: supabase db reset  (which applies migrations + this seed)
--
-- Emails and the fixed UUIDs below are development-only conveniences. They are
-- inserted only if the matching auth.users row exists, so this seed is safe to
-- run against a database where the users have not been created yet.

do $$
declare
    org_a uuid := '11111111-1111-1111-1111-111111111111';
    org_b uuid := '22222222-2222-2222-2222-222222222222';
    bldg  uuid := '33333333-3333-3333-3333-333333333333';
    mapv  uuid := '44444444-4444-4444-4444-444444444444';

    -- Graph stable ids mirror what the iPhone would upload.
    n_room  uuid := 'a0000000-0000-0000-0000-000000000001';
    n_inter uuid := 'a0000000-0000-0000-0000-000000000002';
    n_stair uuid := 'a0000000-0000-0000-0000-000000000003';
    n_eexit uuid := 'a0000000-0000-0000-0000-000000000004';
    n_elev  uuid := 'a0000000-0000-0000-0000-000000000005';
    n_wexit uuid := 'a0000000-0000-0000-0000-000000000006';
    n_refug uuid := 'a0000000-0000-0000-0000-000000000007';

    e_room_inter  uuid := 'b0000000-0000-0000-0000-000000000001';
    e_inter_stair uuid := 'b0000000-0000-0000-0000-000000000002';
    e_stair_exit  uuid := 'b0000000-0000-0000-0000-000000000003';
    e_inter_elev  uuid := 'b0000000-0000-0000-0000-000000000004';
    e_elev_exit   uuid := 'b0000000-0000-0000-0000-000000000005';
    e_inter_refug uuid := 'b0000000-0000-0000-0000-000000000006';

    admin_uid  uuid;
    viewer_uid uuid;
    other_uid  uuid;
begin
    insert into public.organizations (id, name)
    values (org_a, 'Bellarmine College Preparatory'),
           (org_b, 'Unrelated School District')
    on conflict (id) do nothing;

    insert into public.buildings (id, organization_id, name, address)
    values (bldg, org_a, 'Wade Academic Center', '960 W Hedding St, San Jose, CA')
    on conflict (id) do nothing;

    insert into public.map_versions (id, building_id, version, status)
    values (mapv, bldg, 1, 'draft')
    on conflict (id) do nothing;

    -- Positions match the iOS layout: X/Z metres, Y is the capture height.
    insert into public.route_nodes (map_version_id, stable_id, floor_id, name, type, position) values
        (mapv, n_room,  'floor-2', 'Room 214',             'room',         '{"x":0,"y":1.4,"z":0}'),
        (mapv, n_inter, 'floor-2', 'Central Intersection', 'intersection', '{"x":0,"y":1.4,"z":10}'),
        (mapv, n_stair, 'floor-2', 'East Stairwell',       'stairwell',    '{"x":10,"y":1.4,"z":10}'),
        (mapv, n_eexit, 'floor-2', 'East Exit',            'exit',         '{"x":14,"y":1.4,"z":10}'),
        (mapv, n_elev,  'floor-2', 'Elevator',             'elevator',     '{"x":-10,"y":1.4,"z":10}'),
        (mapv, n_wexit, 'floor-2', 'West Exit',            'exit',         '{"x":-40,"y":1.4,"z":10}'),
        (mapv, n_refug, 'floor-2', 'Refuge Area',          'refugeArea',   '{"x":0,"y":1.4,"z":22}')
    on conflict (map_version_id, stable_id) do nothing;

    insert into public.route_edges (
        map_version_id, stable_id, from_node_stable_id, to_node_stable_id,
        distance_meters, contains_stairs, requires_elevator, wheelchair_accessible
    ) values
        (mapv, e_room_inter,  n_room,  n_inter, 10, false, false, true),
        (mapv, e_inter_stair, n_inter, n_stair, 10, true,  false, false),
        (mapv, e_stair_exit,  n_stair, n_eexit,  4, true,  false, false),
        (mapv, e_inter_elev,  n_inter, n_elev,  10, false, true,  true),
        (mapv, e_elev_exit,   n_elev,  n_wexit, 30, false, true,  true),
        (mapv, e_inter_refug, n_inter, n_refug, 12, false, false, true)
    on conflict (map_version_id, stable_id) do nothing;

    -- Publish directly; publish_map_version() requires an authenticated admin,
    -- which a seed script does not have.
    update public.map_versions set status = 'published', published_at = now() where id = mapv;
    update public.buildings set active_map_version_id = mapv where id = bldg;

    -- Attach profiles only for auth users that actually exist.
    select id into admin_uid  from auth.users where email = 'admin@egress.test';
    select id into viewer_uid from auth.users where email = 'viewer@egress.test';
    select id into other_uid  from auth.users where email = 'outsider@egress.test';

    if admin_uid is not null then
        insert into public.profiles (id, organization_id, role, display_name)
        values (admin_uid, org_a, 'admin', 'Demo Admin')
        on conflict (id) do update set organization_id = excluded.organization_id, role = excluded.role;
    end if;

    if viewer_uid is not null then
        insert into public.profiles (id, organization_id, role, display_name)
        values (viewer_uid, org_a, 'viewer', 'Demo Occupant')
        on conflict (id) do update set organization_id = excluded.organization_id, role = excluded.role;
    end if;

    -- Belongs to a different organization; used to prove tenant isolation.
    if other_uid is not null then
        insert into public.profiles (id, organization_id, role, display_name)
        values (other_uid, org_b, 'admin', 'Outsider Admin')
        on conflict (id) do update set organization_id = excluded.organization_id, role = excluded.role;
    end if;
end $$;
