-- Cached OSM building footprint for the 3D focus view.
--
-- Additive only. Both columns are null until the focus view resolves a
-- footprint for the building's anchor; a null footprint means "not looked up
-- yet, or OSM has nothing here" and the client falls back to the hull of its
-- own mapped nodes.
--
-- No new RLS policy: these are columns on `buildings`, which already carries
-- the owner-only pattern from 20260806000200 — `buildings_read_own_org`
-- (select) and `buildings_admin_update` (update), both gated on
-- `organization_id = current_org_id()`. Same reasoning as the georeference
-- columns in 20260806000900.

alter table public.buildings
    add column if not exists footprint_geojson jsonb,
    add column if not exists footprint_height_m double precision
        check (footprint_height_m is null or footprint_height_m > 0);
