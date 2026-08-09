-- Building georeference (anchor). Ties a building's AR coordinate space to a
-- real-world location, so the dashboard can place it on a map and, later, an
-- app can align a world map to true north and geographic position.
--
-- Additive only. Every existing row keeps working: the new columns default to
-- "unset" (null) for position/address, or the identity transform (0 altitude,
-- 0 heading, 1 scale) for the alignment fields.
--
-- No new RLS policy: `buildings` already carries the owner-only pattern from
-- 20260806000200 — `buildings_read_own_org` (select) and `buildings_admin_update`
-- (update), both gated on `organization_id = current_org_id()`, update also on
-- `is_admin()`. These columns live on that same row, so they inherit those
-- policies automatically; adding a second policy on the same table would only
-- duplicate what already governs it.

alter table public.buildings
    add column if not exists anchor_lat double precision
        check (anchor_lat is null or anchor_lat between -90 and 90),
    add column if not exists anchor_lng double precision
        check (anchor_lng is null or anchor_lng between -180 and 180),
    add column if not exists anchor_alt_m double precision not null default 0,
    add column if not exists heading_deg double precision not null default 0,
    add column if not exists scale double precision not null default 1
        check (scale > 0),
    add column if not exists formatted_address text;
