-- Publishing a map version must also publish its building.
--
-- Occupants only see buildings with status = 'published' (see the RLS policy in
-- 20260806000500). Before this, publishing a map left the building as a draft,
-- so a freshly published building stayed invisible to every student.

create or replace function public.publish_map_version(p_map_version_id uuid)
returns public.map_versions
language plpgsql
security definer
set search_path = public
as $$
declare
    v_version public.map_versions;
    v_node_count integer;
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
    if v_node_count = 0 then
        raise exception 'Cannot publish a map with no nodes';
    end if;

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

    if v_previous is not null and v_previous <> p_map_version_id then
        update public.map_versions set status = 'archived' where id = v_previous;
    end if;

    update public.map_versions
       set status = 'published', published_at = now()
     where id = p_map_version_id
     returning * into v_version;

    -- The building becomes visible to occupants at the same moment.
    update public.buildings
       set active_map_version_id = p_map_version_id,
           status = 'published'
     where id = v_version.building_id;

    return v_version;
end;
$$;

-- Repair anything published before this fix.
update public.buildings
   set status = 'published'
 where active_map_version_id is not null and status = 'draft';
