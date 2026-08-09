-- Row Level Security. Every exposed table is protected; the default is denial.
--
-- The two helpers are SECURITY DEFINER so that reading `profiles` to resolve the
-- caller's org does not re-enter `profiles` RLS and recurse.

create or replace function public.current_org_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
    select organization_id from public.profiles where id = auth.uid();
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select coalesce(
        (select role = 'admin' from public.profiles where id = auth.uid()),
        false
    );
$$;

-- Building belongs to the caller's organization.
create or replace function public.can_access_building(target uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1 from public.buildings b
        where b.id = target
          and b.organization_id = public.current_org_id()
    );
$$;

create or replace function public.can_admin_building(target uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select public.is_admin() and public.can_access_building(target);
$$;

alter table public.organizations     enable row level security;
alter table public.profiles          enable row level security;
alter table public.buildings         enable row level security;
alter table public.map_versions      enable row level security;
alter table public.route_nodes       enable row level security;
alter table public.route_edges       enable row level security;
alter table public.live_edge_states  enable row level security;
alter table public.live_node_states  enable row level security;
alter table public.user_reports      enable row level security;
alter table public.live_state_audit  enable row level security;

-- MARK: Organizations / profiles --------------------------------------------

create policy organizations_read_own on public.organizations
    for select to authenticated
    using (id = public.current_org_id());

create policy profiles_read_self on public.profiles
    for select to authenticated
    using (id = auth.uid() or organization_id = public.current_org_id());

-- Role changes are an administrative action performed server-side; no client
-- policy grants insert, update or delete on profiles.

-- MARK: Buildings ------------------------------------------------------------

create policy buildings_read_own_org on public.buildings
    for select to authenticated
    using (organization_id = public.current_org_id());

create policy buildings_admin_insert on public.buildings
    for insert to authenticated
    with check (public.is_admin() and organization_id = public.current_org_id());

create policy buildings_admin_update on public.buildings
    for update to authenticated
    using (public.is_admin() and organization_id = public.current_org_id())
    with check (public.is_admin() and organization_id = public.current_org_id());

-- MARK: Map versions ---------------------------------------------------------

-- Occupants see published versions only; admins also see drafts they are building.
create policy map_versions_read on public.map_versions
    for select to authenticated
    using (
        public.can_access_building(building_id)
        and (status = 'published' or public.is_admin())
    );

create policy map_versions_admin_insert on public.map_versions
    for insert to authenticated
    with check (public.can_admin_building(building_id));

create policy map_versions_admin_update on public.map_versions
    for update to authenticated
    using (public.can_admin_building(building_id))
    with check (public.can_admin_building(building_id));

-- MARK: Graph ----------------------------------------------------------------

create policy route_nodes_read on public.route_nodes
    for select to authenticated
    using (exists (
        select 1 from public.map_versions mv
        where mv.id = route_nodes.map_version_id
          and public.can_access_building(mv.building_id)
          and (mv.status = 'published' or public.is_admin())
    ));

create policy route_nodes_admin_write on public.route_nodes
    for insert to authenticated
    with check (exists (
        select 1 from public.map_versions mv
        where mv.id = route_nodes.map_version_id
          and public.can_admin_building(mv.building_id)
          -- A published map is immutable; structural change means a new version.
          and mv.status = 'draft'
    ));

create policy route_edges_read on public.route_edges
    for select to authenticated
    using (exists (
        select 1 from public.map_versions mv
        where mv.id = route_edges.map_version_id
          and public.can_access_building(mv.building_id)
          and (mv.status = 'published' or public.is_admin())
    ));

create policy route_edges_admin_write on public.route_edges
    for insert to authenticated
    with check (exists (
        select 1 from public.map_versions mv
        where mv.id = route_edges.map_version_id
          and public.can_admin_building(mv.building_id)
          and mv.status = 'draft'
    ));

-- MARK: Live state -----------------------------------------------------------
-- Occupants read. Only admins write. There is deliberately no occupant
-- insert/update policy: one person's report must never change every phone.

create policy live_edge_states_read on public.live_edge_states
    for select to authenticated
    using (public.can_access_building(building_id));

create policy live_edge_states_admin_insert on public.live_edge_states
    for insert to authenticated
    with check (public.can_admin_building(building_id));

create policy live_edge_states_admin_update on public.live_edge_states
    for update to authenticated
    using (public.can_admin_building(building_id))
    with check (public.can_admin_building(building_id));

create policy live_edge_states_admin_delete on public.live_edge_states
    for delete to authenticated
    using (public.can_admin_building(building_id));

create policy live_node_states_read on public.live_node_states
    for select to authenticated
    using (public.can_access_building(building_id));

create policy live_node_states_admin_insert on public.live_node_states
    for insert to authenticated
    with check (public.can_admin_building(building_id));

create policy live_node_states_admin_update on public.live_node_states
    for update to authenticated
    using (public.can_admin_building(building_id))
    with check (public.can_admin_building(building_id));

create policy live_node_states_admin_delete on public.live_node_states
    for delete to authenticated
    using (public.can_admin_building(building_id));

-- MARK: User reports ---------------------------------------------------------

create policy user_reports_read on public.user_reports
    for select to authenticated
    using (
        public.can_access_building(building_id)
        and (reporter_id = auth.uid() or public.is_admin())
    );

-- Occupants may report, but only as themselves and only about their own org.
create policy user_reports_insert_own on public.user_reports
    for insert to authenticated
    with check (
        public.can_access_building(building_id)
        and reporter_id = auth.uid()
        and status = 'pending'
    );

-- Only admins triage. A reporter cannot verify their own report.
create policy user_reports_admin_review on public.user_reports
    for update to authenticated
    using (public.can_admin_building(building_id))
    with check (public.can_admin_building(building_id));

-- MARK: Audit ----------------------------------------------------------------
-- Readable by admins, written only by the SECURITY DEFINER trigger.
-- No insert/update/delete policy exists, so the log is append-only from clients.

create policy live_state_audit_admin_read on public.live_state_audit
    for select to authenticated
    using (public.can_admin_building(building_id));
