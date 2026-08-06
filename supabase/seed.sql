-- Demo data for local development.
--
-- Test users are created HERE, not by hand in Studio. `supabase db reset` drops
-- and recreates the database, which would destroy manually created auth users;
-- creating them in the seed makes the whole setup reproducible in one command.
--
-- LOCAL DEVELOPMENT ONLY. These are throwaway credentials for a database that
-- listens on localhost. Never run this against a hosted project.

-- pgcrypto lives in the `extensions` schema on Supabase, so crypt()/gen_salt()
-- are called schema-qualified rather than relying on search_path.

-- MARK: Reproducible test users ----------------------------------------------

create or replace function pg_temp.create_test_user(
    p_id uuid,
    p_email text,
    p_password text
) returns uuid
language plpgsql
as $$
begin
    insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
        created_at, updated_at
    ) values (
        '00000000-0000-0000-0000-000000000000',
        p_id,
        'authenticated',
        'authenticated',
        p_email,
        extensions.crypt(p_password, extensions.gen_salt('bf')),
        now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{}'::jsonb,
        now(),
        now()
    )
    on conflict (id) do update
        set email = excluded.email,
            encrypted_password = excluded.encrypted_password,
            email_confirmed_at = excluded.email_confirmed_at;

    -- GoTrue requires a matching identity row for password sign-in.
    insert into auth.identities (
        id, user_id, identity_data, provider, provider_id,
        last_sign_in_at, created_at, updated_at
    ) values (
        gen_random_uuid(),
        p_id,
        jsonb_build_object('sub', p_id::text, 'email', p_email, 'email_verified', true),
        'email',
        p_id::text,
        now(), now(), now()
    )
    on conflict (provider_id, provider) do update
        set identity_data = excluded.identity_data,
            updated_at = now();

    return p_id;
end;
$$;

-- MARK: Demo tenancy and graph ------------------------------------------------

do $$
declare
    org_a uuid := '11111111-1111-1111-1111-111111111111';
    org_b uuid := '22222222-2222-2222-2222-222222222222';
    bldg  uuid := '33333333-3333-3333-3333-333333333333';
    mapv  uuid := '44444444-4444-4444-4444-444444444444';

    admin_uid    uuid := '55555555-5555-5555-5555-555555555551';
    viewer_uid   uuid := '55555555-5555-5555-5555-555555555552';
    outsider_uid uuid := '55555555-5555-5555-5555-555555555553';

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
begin
    perform pg_temp.create_test_user(admin_uid,    'admin@egress.test',    'egress-admin-pw');
    perform pg_temp.create_test_user(viewer_uid,   'viewer@egress.test',   'egress-viewer-pw');
    perform pg_temp.create_test_user(outsider_uid, 'outsider@egress.test', 'egress-outsider-pw');

    insert into public.organizations (id, name)
    values (org_a, 'Bellarmine College Preparatory'),
           (org_b, 'Unrelated School District')
    on conflict (id) do nothing;

    -- outsider is an ADMIN of a different org: proves that being an admin is not
    -- enough, the organization must match too.
    insert into public.profiles (id, organization_id, role, display_name) values
        (admin_uid,    org_a, 'admin',  'Demo Admin'),
        (viewer_uid,   org_a, 'viewer', 'Demo Occupant'),
        (outsider_uid, org_b, 'admin',  'Outsider Admin')
    on conflict (id) do update
        set organization_id = excluded.organization_id,
            role = excluded.role;

    insert into public.buildings (id, organization_id, name, address)
    values (bldg, org_a, 'Wade Academic Center', '960 W Hedding St, San Jose, CA')
    on conflict (id) do nothing;

    insert into public.map_versions (id, building_id, version, status, created_by)
    values (mapv, bldg, 1, 'draft', admin_uid)
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

    -- Published directly: publish_map_version() requires an authenticated admin,
    -- which a seed script does not have.
    update public.map_versions set status = 'published', published_at = now() where id = mapv;
    update public.buildings set active_map_version_id = mapv where id = bldg;
end $$;
