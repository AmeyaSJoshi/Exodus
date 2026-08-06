-- Server-side operations that must be atomic or must enforce rules RLS cannot
-- express on its own. All are SECURITY DEFINER and re-check authorisation
-- explicitly, so being definer never widens access.

-- MARK: Publishing -----------------------------------------------------------

-- Validates a draft, publishes it, archives the previous version and repoints
-- the building — all in one transaction. Publishing a structurally invalid map
-- is impossible rather than merely discouraged.
create or replace function public.publish_map_version(p_map_version_id uuid)
returns public.map_versions
language plpgsql
security definer
set search_path = public
as $$
declare
    v_version public.map_versions;
    v_node_count integer;
    v_edge_count integer;
    v_orphan_count integer;
    v_previous uuid;
begin
    select * into v_version from public.map_versions where id = p_map_version_id;
    if v_version.id is null then
        raise exception 'Map version % not found', p_map_version_id;
    end if;

    if not public.can_admin_building(v_version.building_id) then
        raise exception 'Not authorised to publish maps for this building';
    end if;

    if v_version.status <> 'draft' then
        raise exception 'Only a draft can be published (status is %)', v_version.status;
    end if;

    select count(*) into v_node_count from public.route_nodes where map_version_id = p_map_version_id;
    select count(*) into v_edge_count from public.route_edges where map_version_id = p_map_version_id;

    if v_node_count = 0 then
        raise exception 'Cannot publish a map with no nodes';
    end if;

    -- Composite FKs already guarantee this, but an explicit check turns a
    -- constraint violation into a readable error for the dashboard.
    select count(*) into v_orphan_count
    from public.route_edges e
    where e.map_version_id = p_map_version_id
      and (
        not exists (select 1 from public.route_nodes n
                    where n.map_version_id = e.map_version_id and n.stable_id = e.from_node_stable_id)
        or not exists (select 1 from public.route_nodes n
                       where n.map_version_id = e.map_version_id and n.stable_id = e.to_node_stable_id)
      );

    if v_orphan_count > 0 then
        raise exception '% edge(s) reference nodes that are not in this version', v_orphan_count;
    end if;

    select active_map_version_id into v_previous
    from public.buildings where id = v_version.building_id;

    -- Older versions are archived, never deleted.
    if v_previous is not null and v_previous <> p_map_version_id then
        update public.map_versions set status = 'archived' where id = v_previous;
    end if;

    update public.map_versions
       set status = 'published', published_at = now()
     where id = p_map_version_id
     returning * into v_version;

    update public.buildings
       set active_map_version_id = p_map_version_id
     where id = v_version.building_id;

    return v_version;
end;
$$;

-- Allocates the next version number for a building and creates the draft.
create or replace function public.create_draft_map_version(p_building_id uuid)
returns public.map_versions
language plpgsql
security definer
set search_path = public
as $$
declare
    v_next integer;
    v_row public.map_versions;
begin
    if not public.can_admin_building(p_building_id) then
        raise exception 'Not authorised to create map versions for this building';
    end if;

    select coalesce(max(version), 0) + 1 into v_next
    from public.map_versions where building_id = p_building_id;

    insert into public.map_versions (building_id, version, status, created_by)
    values (p_building_id, v_next, 'draft', auth.uid())
    returning * into v_row;

    return v_row;
end;
$$;

-- MARK: Live state -----------------------------------------------------------

-- Upsert keyed on the stable id, so repeated updates to the same segment do not
-- accumulate rows and each one gets a fresh revision from the trigger.
create or replace function public.set_edge_state(
    p_building_id uuid,
    p_edge_stable_id uuid,
    p_status text,
    p_hazard_type text default null,
    p_reason text default null,
    p_severity integer default 3,
    p_expires_at timestamptz default null
)
returns public.live_edge_states
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row public.live_edge_states;
begin
    if not public.can_admin_building(p_building_id) then
        raise exception 'Not authorised to change live state for this building';
    end if;

    insert into public.live_edge_states (
        building_id, edge_stable_id, status, hazard_type, reason, severity, updated_by, expires_at
    ) values (
        p_building_id, p_edge_stable_id, p_status, p_hazard_type, p_reason,
        coalesce(p_severity, 3), auth.uid(), p_expires_at
    )
    on conflict (edge_stable_id) do update
        set status      = excluded.status,
            hazard_type = excluded.hazard_type,
            reason      = excluded.reason,
            severity    = excluded.severity,
            updated_by  = excluded.updated_by,
            expires_at  = excluded.expires_at,
            building_id = excluded.building_id
    returning * into v_row;

    return v_row;
end;
$$;

create or replace function public.set_node_state(
    p_building_id uuid,
    p_node_stable_id uuid,
    p_status text,
    p_hazard_type text default null,
    p_reason text default null,
    p_severity integer default 3,
    p_expires_at timestamptz default null
)
returns public.live_node_states
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row public.live_node_states;
begin
    if not public.can_admin_building(p_building_id) then
        raise exception 'Not authorised to change live state for this building';
    end if;

    insert into public.live_node_states (
        building_id, node_stable_id, status, hazard_type, reason, severity, updated_by, expires_at
    ) values (
        p_building_id, p_node_stable_id, p_status, p_hazard_type, p_reason,
        coalesce(p_severity, 3), auth.uid(), p_expires_at
    )
    on conflict (node_stable_id) do update
        set status      = excluded.status,
            hazard_type = excluded.hazard_type,
            reason      = excluded.reason,
            severity    = excluded.severity,
            updated_by  = excluded.updated_by,
            expires_at  = excluded.expires_at,
            building_id = excluded.building_id
    returning * into v_row;

    return v_row;
end;
$$;

-- "Clear" writes an `available` row rather than deleting, so subscribers receive
-- an event with a newer revision instead of having to infer the removal.
create or replace function public.clear_edge_state(p_building_id uuid, p_edge_stable_id uuid)
returns public.live_edge_states
language sql
security definer
set search_path = public
as $$
    select public.set_edge_state(p_building_id, p_edge_stable_id, 'available', null, null, 1, null);
$$;

create or replace function public.clear_node_state(p_building_id uuid, p_node_stable_id uuid)
returns public.live_node_states
language sql
security definer
set search_path = public
as $$
    select public.set_node_state(p_building_id, p_node_stable_id, 'available', null, null, 1, null);
$$;

-- MARK: Report triage --------------------------------------------------------

-- Verifying a report promotes it to building-wide live state atomically.
-- Rejecting it records the decision and changes nothing else — the reporting
-- phone keeps its own personal overlay for the rest of the session.
create or replace function public.review_report(
    p_report_id uuid,
    p_status text,
    p_hazard_type text default null,
    p_reason text default null,
    p_severity integer default 3
)
returns public.user_reports
language plpgsql
security definer
set search_path = public
as $$
declare
    v_report public.user_reports;
begin
    if p_status not in ('verified', 'rejected') then
        raise exception 'Review status must be verified or rejected';
    end if;

    select * into v_report from public.user_reports where id = p_report_id;
    if v_report.id is null then
        raise exception 'Report % not found', p_report_id;
    end if;

    if not public.can_admin_building(v_report.building_id) then
        raise exception 'Not authorised to review reports for this building';
    end if;

    update public.user_reports
       set status = p_status, reviewed_by = auth.uid(), reviewed_at = now()
     where id = p_report_id
     returning * into v_report;

    if p_status = 'verified' then
        if v_report.edge_stable_id is not null then
            perform public.set_edge_state(
                v_report.building_id, v_report.edge_stable_id, 'blocked',
                coalesce(p_hazard_type, v_report.report_type),
                coalesce(p_reason, v_report.description), p_severity, null
            );
        elsif v_report.node_stable_id is not null then
            perform public.set_node_state(
                v_report.building_id, v_report.node_stable_id, 'blocked',
                coalesce(p_hazard_type, v_report.report_type),
                coalesce(p_reason, v_report.description), p_severity, null
            );
        end if;
    end if;

    return v_report;
end;
$$;

-- MARK: Snapshot -------------------------------------------------------------

-- One round trip for the pre-navigation snapshot. Expired states are reported as
-- `available` so a client that has been offline past an expiry does not keep
-- honouring it.
create or replace function public.building_state_snapshot(p_building_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_result jsonb;
begin
    if not public.can_access_building(p_building_id) then
        raise exception 'Not authorised to read this building';
    end if;

    select jsonb_build_object(
        'building_id', p_building_id,
        'active_map_version_id', (select active_map_version_id from public.buildings where id = p_building_id),
        'revision', coalesce((
            select max(r) from (
                select max(revision) as r from public.live_edge_states where building_id = p_building_id
                union all
                select max(revision) as r from public.live_node_states where building_id = p_building_id
            ) revisions
        ), 0),
        'edges', coalesce((
            select jsonb_agg(jsonb_build_object(
                'edge_stable_id', edge_stable_id,
                'status', case when expires_at is not null and expires_at <= now() then 'available' else status end,
                'hazard_type', hazard_type,
                'reason', reason,
                'severity', severity,
                'revision', revision,
                'expires_at', expires_at
            ))
            from public.live_edge_states where building_id = p_building_id
        ), '[]'::jsonb),
        'nodes', coalesce((
            select jsonb_agg(jsonb_build_object(
                'node_stable_id', node_stable_id,
                'status', case when expires_at is not null and expires_at <= now() then 'available' else status end,
                'hazard_type', hazard_type,
                'reason', reason,
                'severity', severity,
                'revision', revision,
                'expires_at', expires_at
            ))
            from public.live_node_states where building_id = p_building_id
        ), '[]'::jsonb)
    ) into v_result;

    return v_result;
end;
$$;

revoke all on function public.publish_map_version(uuid) from public;
revoke all on function public.create_draft_map_version(uuid) from public;
revoke all on function public.set_edge_state(uuid, uuid, text, text, text, integer, timestamptz) from public;
revoke all on function public.set_node_state(uuid, uuid, text, text, text, integer, timestamptz) from public;
revoke all on function public.clear_edge_state(uuid, uuid) from public;
revoke all on function public.clear_node_state(uuid, uuid) from public;
revoke all on function public.review_report(uuid, text, text, text, integer) from public;
revoke all on function public.building_state_snapshot(uuid) from public;

grant execute on function public.publish_map_version(uuid) to authenticated;
grant execute on function public.create_draft_map_version(uuid) to authenticated;
grant execute on function public.set_edge_state(uuid, uuid, text, text, text, integer, timestamptz) to authenticated;
grant execute on function public.set_node_state(uuid, uuid, text, text, text, integer, timestamptz) to authenticated;
grant execute on function public.clear_edge_state(uuid, uuid) to authenticated;
grant execute on function public.clear_node_state(uuid, uuid) to authenticated;
grant execute on function public.review_report(uuid, text, text, text, integer) to authenticated;
grant execute on function public.building_state_snapshot(uuid) to authenticated;
