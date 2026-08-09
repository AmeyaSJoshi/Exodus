-- Buildings workflow: drafts, floors, map artifacts, room aliases.
-- Additive only. Every existing row keeps working: `buildings.status` defaults
-- to the state each row is already in, and a default floor is backfilled.

-- MARK: Building drafts -------------------------------------------------------

alter table public.buildings
    add column if not exists status text not null default 'draft'
        check (status in ('draft', 'published', 'archived')),
    add column if not exists description text,
    add column if not exists created_by uuid references auth.users (id);

-- Anything already carrying an active map version is, by definition, published.
update public.buildings set status = 'published'
 where active_map_version_id is not null and status = 'draft';

create index if not exists buildings_status_idx on public.buildings (organization_id, status);

-- Drafts must not leak. The original policy predated building drafts and let any
-- org member read every building; occupants now see published buildings only.
drop policy if exists buildings_read_own_org on public.buildings;
create policy buildings_read_own_org on public.buildings
    for select to authenticated
    using (
        organization_id = public.current_org_id()
        and (status = 'published' or public.is_admin())
    );

-- MARK: Floors ----------------------------------------------------------------

create table if not exists public.floors (
    id          uuid primary key default gen_random_uuid(),
    building_id uuid not null references public.buildings (id) on delete cascade,
    name        text not null,
    level       integer not null default 0,
    is_default  boolean not null default false,
    created_at  timestamptz not null default now(),
    unique (building_id, level)
);

create index if not exists floors_building_idx on public.floors (building_id);

-- Every existing building gets one default floor so the single-floor UI has a
-- real row to point at and multi-floor can arrive later without a migration.
insert into public.floors (building_id, name, level, is_default)
select b.id, 'Default Floor', 0, true
from public.buildings b
where not exists (select 1 from public.floors f where f.building_id = b.id);

alter table public.route_nodes
    add column if not exists floor_ref uuid references public.floors (id) on delete set null;

-- MARK: Map artifacts ---------------------------------------------------------
-- Binary payloads (ARWorldMap, reference images) live in Storage; this table
-- holds the references plus integrity data.

create table if not exists public.map_artifacts (
    id             uuid primary key default gen_random_uuid(),
    map_version_id uuid not null references public.map_versions (id) on delete cascade,
    building_id    uuid not null references public.buildings (id) on delete cascade,
    floor_id       uuid references public.floors (id) on delete set null,
    zone_id        uuid,
    kind           text not null check (kind in ('worldmap', 'reference_image', 'floorplan', 'package')),
    storage_path   text not null,
    byte_size      bigint not null default 0,
    checksum       text,
    schema_version integer not null default 1,
    metadata       jsonb not null default '{}'::jsonb,
    created_at     timestamptz not null default now(),
    unique (map_version_id, kind, storage_path)
);

create index if not exists map_artifacts_version_idx on public.map_artifacts (map_version_id);
create index if not exists map_artifacts_building_idx on public.map_artifacts (building_id);
create index if not exists map_artifacts_kind_idx on public.map_artifacts (map_version_id, kind);

-- MARK: Room aliases (localization / OCR) --------------------------------------

create table if not exists public.room_aliases (
    id             uuid primary key default gen_random_uuid(),
    map_version_id uuid not null references public.map_versions (id) on delete cascade,
    node_stable_id uuid not null,
    alias          text not null,
    source         text not null default 'manual' check (source in ('manual', 'ocr', 'sign')),
    created_at     timestamptz not null default now(),
    unique (map_version_id, node_stable_id, alias)
);

create index if not exists room_aliases_version_idx on public.room_aliases (map_version_id);
create index if not exists room_aliases_alias_idx on public.room_aliases (map_version_id, alias);

-- MARK: RLS -------------------------------------------------------------------

alter table public.floors        enable row level security;
alter table public.map_artifacts enable row level security;
alter table public.room_aliases  enable row level security;

create policy floors_read on public.floors
    for select to authenticated
    using (public.can_access_building(building_id));

create policy floors_admin_write on public.floors
    for all to authenticated
    using (public.can_admin_building(building_id))
    with check (public.can_admin_building(building_id));

-- Occupants may only see artifacts of a PUBLISHED version. Draft artifacts stay
-- invisible until the version is published.
create policy map_artifacts_read on public.map_artifacts
    for select to authenticated
    using (
        public.can_access_building(building_id)
        and (
            public.is_admin()
            or exists (
                select 1 from public.map_versions mv
                where mv.id = map_artifacts.map_version_id and mv.status = 'published'
            )
        )
    );

create policy map_artifacts_admin_write on public.map_artifacts
    for all to authenticated
    using (public.can_admin_building(building_id))
    with check (public.can_admin_building(building_id));

create policy room_aliases_read on public.room_aliases
    for select to authenticated
    using (exists (
        select 1 from public.map_versions mv
        where mv.id = room_aliases.map_version_id
          and public.can_access_building(mv.building_id)
          and (mv.status = 'published' or public.is_admin())
    ));

create policy room_aliases_admin_write on public.room_aliases
    for all to authenticated
    using (exists (
        select 1 from public.map_versions mv
        where mv.id = room_aliases.map_version_id and public.can_admin_building(mv.building_id)
    ))
    with check (exists (
        select 1 from public.map_versions mv
        where mv.id = room_aliases.map_version_id and public.can_admin_building(mv.building_id)
    ));

grant select on public.floors        to authenticated;
grant select on public.map_artifacts to authenticated;
grant select on public.room_aliases  to authenticated;
grant insert, update, delete on public.floors        to authenticated;
grant insert, update, delete on public.map_artifacts to authenticated;
grant insert, update, delete on public.room_aliases  to authenticated;

-- MARK: RPCs ------------------------------------------------------------------

-- Creates a building in the CALLER's organization. The organization is read
-- from the profile, never supplied by the client, so a mapper cannot create a
-- building somewhere else even by tampering with the request.
create or replace function public.create_building(
    p_name text,
    p_address text default null,
    p_description text default null
)
returns public.buildings
language plpgsql
security definer
set search_path = public
as $$
declare
    v_org uuid;
    v_row public.buildings;
begin
    if not public.is_admin() then
        raise exception 'Only an administrator or mapper can create a building';
    end if;

    v_org := public.current_org_id();
    if v_org is null then
        raise exception 'Your account is not assigned to an organization';
    end if;

    insert into public.buildings (organization_id, name, address, description, status, created_by)
    values (v_org, p_name, p_address, p_description, 'draft', auth.uid())
    returning * into v_row;

    insert into public.floors (building_id, name, level, is_default)
    values (v_row.id, 'Default Floor', 0, true);

    return v_row;
end;
$$;

-- Everything an occupant needs to list buildings without N+1 round trips.
create or replace function public.organization_buildings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id,
        'name', b.name,
        'address', b.address,
        'description', b.description,
        'status', b.status,
        'active_map_version_id', b.active_map_version_id,
        'version', mv.version,
        'published_at', mv.published_at,
        'node_count', (select count(*) from public.route_nodes n where n.map_version_id = b.active_map_version_id),
        'artifact_count', (select count(*) from public.map_artifacts a where a.map_version_id = b.active_map_version_id)
    ) order by b.name), '[]'::jsonb)
    from public.buildings b
    left join public.map_versions mv on mv.id = b.active_map_version_id
    where b.organization_id = public.current_org_id()
      and (b.status = 'published' or public.is_admin());
$$;

-- The caller's own role and organization, so the app never asks for a UUID.
create or replace function public.my_profile()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
    select coalesce((
        select jsonb_build_object(
            'user_id', p.id,
            'organization_id', p.organization_id,
            'organization_name', o.name,
            'role', p.role,
            'display_name', p.display_name
        )
        from public.profiles p
        join public.organizations o on o.id = p.organization_id
        where p.id = auth.uid()
    ), '{}'::jsonb);
$$;

revoke all on function public.create_building(text, text, text) from public;
revoke all on function public.organization_buildings() from public;
revoke all on function public.my_profile() from public;
grant execute on function public.create_building(text, text, text) to authenticated;
grant execute on function public.organization_buildings() to authenticated;
grant execute on function public.my_profile() to authenticated;

-- MARK: Storage ---------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('map-artifacts', 'map-artifacts', false)
on conflict (id) do nothing;

-- Paths are <building_id>/<map_version_id>/<filename>, so the first segment
-- carries the authorization scope.
create policy "map artifacts readable by org" on storage.objects
    for select to authenticated
    using (
        bucket_id = 'map-artifacts'
        and public.can_access_building(((storage.foldername(name))[1])::uuid)
    );

create policy "map artifacts writable by admins" on storage.objects
    for insert to authenticated
    with check (
        bucket_id = 'map-artifacts'
        and public.can_admin_building(((storage.foldername(name))[1])::uuid)
    );

create policy "map artifacts updatable by admins" on storage.objects
    for update to authenticated
    using (
        bucket_id = 'map-artifacts'
        and public.can_admin_building(((storage.foldername(name))[1])::uuid)
    );
