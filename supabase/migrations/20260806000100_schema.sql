-- EGRESS live building state — core schema.
-- Identity note: `id` is a per-row primary key; `stable_id` carries the UUID the
-- iPhone assigned when the zone was mapped. Preserving iOS UUIDs across map
-- versions is impossible if they are the primary key, because the same node must
-- exist in v1 and v2. Live state therefore references `stable_id`, so an
-- administrator's "stairwell blocked" survives a map republish.

create extension if not exists "pgcrypto";

-- MARK: Tenancy -------------------------------------------------------------

create table public.organizations (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    created_at timestamptz not null default now()
);

create table public.profiles (
    id              uuid primary key references auth.users (id) on delete cascade,
    organization_id uuid not null references public.organizations (id) on delete cascade,
    role            text not null default 'viewer' check (role in ('admin', 'viewer')),
    display_name    text,
    created_at      timestamptz not null default now()
);

create index profiles_organization_id_idx on public.profiles (organization_id);

-- MARK: Buildings and map versions ------------------------------------------

create table public.buildings (
    id                    uuid primary key default gen_random_uuid(),
    organization_id       uuid not null references public.organizations (id) on delete cascade,
    name                  text not null,
    address               text,
    -- Set only once a version is validated and published.
    active_map_version_id  uuid,
    created_at            timestamptz not null default now()
);

create index buildings_organization_id_idx on public.buildings (organization_id);

create table public.map_versions (
    id           uuid primary key default gen_random_uuid(),
    building_id  uuid not null references public.buildings (id) on delete cascade,
    version      integer not null,
    status       text not null default 'draft' check (status in ('draft', 'published', 'archived')),
    created_by   uuid references auth.users (id),
    created_at   timestamptz not null default now(),
    published_at timestamptz,
    unique (building_id, version)
);

create index map_versions_building_id_idx on public.map_versions (building_id);
create index map_versions_status_idx on public.map_versions (building_id, status);

alter table public.buildings
    add constraint buildings_active_map_version_fk
    foreign key (active_map_version_id) references public.map_versions (id) on delete set null;

-- MARK: Graph ---------------------------------------------------------------

create table public.route_nodes (
    id             uuid primary key default gen_random_uuid(),
    map_version_id uuid not null references public.map_versions (id) on delete cascade,
    -- The iPhone's RouteNode.id. Durable across map versions.
    stable_id      uuid not null,
    floor_id       text not null default 'default',
    name           text not null,
    type           text not null,
    position       jsonb not null,
    metadata       jsonb not null default '{}'::jsonb,
    unique (map_version_id, stable_id)
);

create index route_nodes_map_version_id_idx on public.route_nodes (map_version_id);
create index route_nodes_stable_id_idx on public.route_nodes (stable_id);
create index route_nodes_floor_idx on public.route_nodes (map_version_id, floor_id);

create table public.route_edges (
    id                    uuid primary key default gen_random_uuid(),
    map_version_id        uuid not null references public.map_versions (id) on delete cascade,
    stable_id             uuid not null,
    from_node_stable_id   uuid not null,
    to_node_stable_id     uuid not null,
    distance_meters       double precision not null check (distance_meters >= 0),
    bidirectional         boolean not null default true,
    contains_stairs       boolean not null default false,
    requires_elevator     boolean not null default false,
    wheelchair_accessible boolean not null default true,
    metadata              jsonb not null default '{}'::jsonb,
    unique (map_version_id, stable_id),
    -- Composite FKs keep edges pointing at nodes *of the same version*.
    constraint route_edges_from_node_fk
        foreign key (map_version_id, from_node_stable_id)
        references public.route_nodes (map_version_id, stable_id) on delete cascade,
    constraint route_edges_to_node_fk
        foreign key (map_version_id, to_node_stable_id)
        references public.route_nodes (map_version_id, stable_id) on delete cascade,
    constraint route_edges_no_self_loop check (from_node_stable_id <> to_node_stable_id)
);

create index route_edges_map_version_id_idx on public.route_edges (map_version_id);
create index route_edges_stable_id_idx on public.route_edges (stable_id);
create index route_edges_from_idx on public.route_edges (map_version_id, from_node_stable_id);
create index route_edges_to_idx on public.route_edges (map_version_id, to_node_stable_id);

-- MARK: Live state ----------------------------------------------------------

-- One global sequence: a client keeps a single integer watermark and can discard
-- any event at or below it, whatever order events arrive in.
create sequence public.live_state_revision_seq as bigint start 1;

create table public.live_edge_states (
    id             uuid primary key default gen_random_uuid(),
    building_id    uuid not null references public.buildings (id) on delete cascade,
    -- References route_edges.stable_id, deliberately not a versioned row.
    edge_stable_id uuid not null unique,
    status         text not null default 'available' check (status in ('available', 'blocked', 'restricted')),
    hazard_type    text,
    reason         text,
    severity       integer not null default 3 check (severity between 1 and 5),
    revision       bigint not null default 0,
    updated_by     uuid references auth.users (id),
    updated_at     timestamptz not null default now(),
    expires_at     timestamptz
);

create index live_edge_states_building_idx on public.live_edge_states (building_id);
create index live_edge_states_revision_idx on public.live_edge_states (building_id, revision);
create index live_edge_states_status_idx on public.live_edge_states (building_id, status);
create index live_edge_states_expires_idx on public.live_edge_states (expires_at);

create table public.live_node_states (
    id             uuid primary key default gen_random_uuid(),
    building_id    uuid not null references public.buildings (id) on delete cascade,
    node_stable_id uuid not null unique,
    status         text not null default 'available' check (status in ('available', 'blocked', 'restricted')),
    hazard_type    text,
    reason         text,
    severity       integer not null default 3 check (severity between 1 and 5),
    revision       bigint not null default 0,
    updated_by     uuid references auth.users (id),
    updated_at     timestamptz not null default now(),
    expires_at     timestamptz
);

create index live_node_states_building_idx on public.live_node_states (building_id);
create index live_node_states_revision_idx on public.live_node_states (building_id, revision);
create index live_node_states_status_idx on public.live_node_states (building_id, status);
create index live_node_states_expires_idx on public.live_node_states (expires_at);

-- Assign the revision server-side; clients and admins never supply it.
create or replace function public.assign_live_revision()
returns trigger
language plpgsql
as $$
begin
    new.revision := nextval('public.live_state_revision_seq');
    new.updated_at := now();
    return new;
end;
$$;

create trigger live_edge_states_revision
    before insert or update on public.live_edge_states
    for each row execute function public.assign_live_revision();

create trigger live_node_states_revision
    before insert or update on public.live_node_states
    for each row execute function public.assign_live_revision();

-- Reject live state for an element that is not in the building's active map.
create or replace function public.validate_live_edge_target()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    active_version uuid;
begin
    select active_map_version_id into active_version
    from public.buildings where id = new.building_id;

    if active_version is null then
        raise exception 'Building % has no published map version', new.building_id;
    end if;

    if not exists (
        select 1 from public.route_edges
        where map_version_id = active_version and stable_id = new.edge_stable_id
    ) then
        raise exception 'Edge % is not part of the active map version', new.edge_stable_id;
    end if;

    return new;
end;
$$;

create or replace function public.validate_live_node_target()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    active_version uuid;
begin
    select active_map_version_id into active_version
    from public.buildings where id = new.building_id;

    if active_version is null then
        raise exception 'Building % has no published map version', new.building_id;
    end if;

    if not exists (
        select 1 from public.route_nodes
        where map_version_id = active_version and stable_id = new.node_stable_id
    ) then
        raise exception 'Node % is not part of the active map version', new.node_stable_id;
    end if;

    return new;
end;
$$;

create trigger live_edge_states_validate
    before insert or update on public.live_edge_states
    for each row execute function public.validate_live_edge_target();

create trigger live_node_states_validate
    before insert or update on public.live_node_states
    for each row execute function public.validate_live_node_target();

-- MARK: Occupant reports ----------------------------------------------------

create table public.user_reports (
    id             uuid primary key default gen_random_uuid(),
    building_id    uuid not null references public.buildings (id) on delete cascade,
    edge_stable_id uuid,
    node_stable_id uuid,
    reporter_id    uuid references auth.users (id) on delete set null,
    report_type    text not null,
    description    text,
    status         text not null default 'pending' check (status in ('pending', 'verified', 'rejected')),
    created_at     timestamptz not null default now(),
    reviewed_by    uuid references auth.users (id),
    reviewed_at    timestamptz,
    constraint user_reports_target_present
        check (edge_stable_id is not null or node_stable_id is not null)
);

create index user_reports_building_idx on public.user_reports (building_id);
create index user_reports_status_idx on public.user_reports (building_id, status);
create index user_reports_created_idx on public.user_reports (created_at desc);
create index user_reports_reporter_idx on public.user_reports (reporter_id);

-- MARK: Audit ---------------------------------------------------------------

-- Append-only. No update or delete policy is ever granted.
create table public.live_state_audit (
    id             uuid primary key default gen_random_uuid(),
    building_id    uuid not null references public.buildings (id) on delete cascade,
    actor_id       uuid references auth.users (id),
    target_kind    text not null check (target_kind in ('edge', 'node')),
    target_id      uuid not null,
    previous_state jsonb,
    new_state      jsonb,
    revision       bigint,
    created_at     timestamptz not null default now()
);

create index live_state_audit_building_idx on public.live_state_audit (building_id, created_at desc);

create or replace function public.record_live_state_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    kind text;
    target uuid;
begin
    if tg_table_name = 'live_edge_states' then
        kind := 'edge';
        target := new.edge_stable_id;
    else
        kind := 'node';
        target := new.node_stable_id;
    end if;

    insert into public.live_state_audit (
        building_id, actor_id, target_kind, target_id, previous_state, new_state, revision
    ) values (
        new.building_id,
        auth.uid(),
        kind,
        target,
        case when tg_op = 'UPDATE' then to_jsonb(old) else null end,
        to_jsonb(new),
        new.revision
    );
    return new;
end;
$$;

create trigger live_edge_states_audit
    after insert or update on public.live_edge_states
    for each row execute function public.record_live_state_audit();

create trigger live_node_states_audit
    after insert or update on public.live_node_states
    for each row execute function public.record_live_state_audit();

-- MARK: Realtime ------------------------------------------------------------

alter publication supabase_realtime add table public.live_edge_states;
alter publication supabase_realtime add table public.live_node_states;

-- Realtime UPDATE/DELETE payloads carry only the primary key unless the replica
-- identity is full; clients need building_id to filter.
alter table public.live_edge_states replica identity full;
alter table public.live_node_states replica identity full;
