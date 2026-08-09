-- Deleting a building. Forward-only.
--
-- There was no delete path at all: a building created by mistake, or a test
-- map, stayed in the organization catalogue forever. Every child table already
-- cascades from buildings, so this only needs to authorize and perform the one
-- delete.
--
-- Storage objects are NOT removed here — SQL cannot delete from a bucket. The
-- client removes them first, and the admin-only storage delete policy added in
-- 20260806000700 is what authorizes that.

create or replace function public.delete_building(p_building_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_org uuid;
begin
    select organization_id into v_org from public.buildings where id = p_building_id;
    if v_org is null then
        raise exception 'Building % not found', p_building_id;
    end if;

    -- Same gate as every other write: an administrator or mapper of the
    -- building's own organization. An occupant is refused outright.
    if not public.can_admin_building(p_building_id) then
        raise exception 'Only an administrator or mapper can delete this building';
    end if;

    -- Cascades to map_versions, route_nodes, route_edges, live state, floors,
    -- map_artifacts and reports.
    delete from public.buildings where id = p_building_id;
end;
$$;

revoke all on function public.delete_building(uuid) from public;
grant execute on function public.delete_building(uuid) to authenticated;

-- Occupants must not be able to reach the table directly either.
drop policy if exists buildings_admin_delete on public.buildings;
create policy buildings_admin_delete on public.buildings
    for delete to authenticated
    using (public.is_admin() and organization_id = public.current_org_id());

grant delete on public.buildings to authenticated;
