-- Table privileges.
--
-- RLS decides *which rows* a role may touch; GRANT decides whether it may touch
-- the table at all. Tables created by a migration receive no default privileges,
-- so without this every policy above is unreachable. The failure mode was safe
-- (permission denied) but the API was unusable.
--
-- `anon` is deliberately granted nothing: an unauthenticated client has no
-- business reading a building's graph or live state.

-- MARK: Read ------------------------------------------------------------------

grant select on public.organizations    to authenticated;
grant select on public.profiles         to authenticated;
grant select on public.buildings        to authenticated;
grant select on public.map_versions     to authenticated;
grant select on public.route_nodes      to authenticated;
grant select on public.route_edges      to authenticated;
grant select on public.live_edge_states to authenticated;
grant select on public.live_node_states to authenticated;
grant select on public.user_reports     to authenticated;
grant select on public.live_state_audit to authenticated;

-- MARK: Write -----------------------------------------------------------------
-- Each of these is still row-filtered by the policies in 20260806000200_rls.sql.
-- Occupants hold the same grants as admins here; the policies are what stop an
-- occupant from writing building-wide live state.

grant insert, update         on public.buildings        to authenticated;
grant insert, update         on public.map_versions     to authenticated;
grant insert                 on public.route_nodes      to authenticated;
grant insert                 on public.route_edges      to authenticated;
grant insert, update, delete on public.live_edge_states to authenticated;
grant insert, update, delete on public.live_node_states to authenticated;
grant insert, update         on public.user_reports     to authenticated;

-- live_state_audit intentionally has no insert/update/delete grant: it is
-- written only by the SECURITY DEFINER trigger, so it is append-only to clients.

-- MARK: Revision sequence ------------------------------------------------------
-- Make the revision trigger run as its owner rather than granting clients
-- USAGE on the sequence, so nobody can call nextval() directly and skew the
-- watermark that clients rely on.

create or replace function public.assign_live_revision()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    new.revision := nextval('public.live_state_revision_seq');
    new.updated_at := now();
    return new;
end;
$$;

-- MARK: Future tables ----------------------------------------------------------

alter default privileges in schema public
    grant select on tables to authenticated;
