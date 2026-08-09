-- Map packages: draft artifacts must not leak, and occupants need a cheap way
-- to find the artifacts of the version they are downloading.
--
-- Forward-only. Nothing already applied is edited.

-- MARK: Storage — draft artifacts are administrator-only --------------------
--
-- The original policy authorized on the building alone, so any organization
-- member could read an object belonging to an unpublished draft. Object paths
-- are <building_id>/<map_version_id>/<file>, so the second segment identifies
-- the version and its status can be checked directly.

create or replace function public.map_version_is_published(p_map_version_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1 from public.map_versions
        where id = p_map_version_id and status = 'published'
    );
$$;

revoke all on function public.map_version_is_published(uuid) from public;
grant execute on function public.map_version_is_published(uuid) to authenticated;

-- A path whose second segment is not a uuid is malformed and is denied.
create or replace function public.storage_path_map_version(p_name text)
returns uuid
language plpgsql
immutable
as $$
declare
    v_segment text;
begin
    v_segment := (storage.foldername(p_name))[2];
    if v_segment is null then
        return null;
    end if;
    return v_segment::uuid;
exception when others then
    return null;
end;
$$;

revoke all on function public.storage_path_map_version(text) from public;
grant execute on function public.storage_path_map_version(text) to authenticated;

drop policy if exists "map artifacts readable by org" on storage.objects;
create policy "map artifacts readable by org" on storage.objects
    for select to authenticated
    using (
        bucket_id = 'map-artifacts'
        and public.can_access_building(((storage.foldername(name))[1])::uuid)
        and (
            -- Mappers and administrators see their own drafts.
            public.can_admin_building(((storage.foldername(name))[1])::uuid)
            -- Everyone else sees published versions only.
            or public.map_version_is_published(public.storage_path_map_version(name))
        )
    );

-- Removing a stored object is how a failed publish cleans up after itself.
-- Occupants were never granted it; make that explicit rather than implicit.
drop policy if exists "map artifacts deletable by admins" on storage.objects;
create policy "map artifacts deletable by admins" on storage.objects
    for delete to authenticated
    using (
        bucket_id = 'map-artifacts'
        and public.can_admin_building(((storage.foldername(name))[1])::uuid)
    );

-- MARK: Package metadata ------------------------------------------------------

-- Everything a client needs to decide whether to download, in one round trip.
-- Returns nothing for a draft version unless the caller may administer the
-- building, matching the map_artifacts read policy.
create or replace function public.map_package_artifacts(p_map_version_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
    select coalesce(jsonb_agg(jsonb_build_object(
        'kind', a.kind,
        'storage_path', a.storage_path,
        'byte_size', a.byte_size,
        'checksum', a.checksum,
        'zone_id', a.zone_id,
        'floor_id', a.floor_id,
        'schema_version', a.schema_version,
        'metadata', a.metadata
    ) order by a.kind, a.storage_path), '[]'::jsonb)
    from public.map_artifacts a
    join public.map_versions mv on mv.id = a.map_version_id
    where a.map_version_id = p_map_version_id
      and public.can_access_building(a.building_id)
      and (mv.status = 'published' or public.can_admin_building(a.building_id));
$$;

revoke all on function public.map_package_artifacts(uuid) from public;
grant execute on function public.map_package_artifacts(uuid) to authenticated;

-- The organization catalogue gains the package schema version, so a client can
-- tell "I cannot read this format" apart from "this map has no artifacts".
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
        'artifact_count', (select count(*) from public.map_artifacts a where a.map_version_id = b.active_map_version_id),
        'package_schema_version', (
            select max(a.schema_version) from public.map_artifacts a
            where a.map_version_id = b.active_map_version_id
        )
    ) order by b.name), '[]'::jsonb)
    from public.buildings b
    left join public.map_versions mv on mv.id = b.active_map_version_id
    where b.organization_id = public.current_org_id()
      and (b.status = 'published' or public.is_admin());
$$;

revoke all on function public.organization_buildings() from public;
grant execute on function public.organization_buildings() to authenticated;
