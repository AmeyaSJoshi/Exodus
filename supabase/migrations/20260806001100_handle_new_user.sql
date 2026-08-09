-- Every authenticated user needs a profile row.
--
-- The dashboard reads its role from public.profiles, and every RLS policy
-- resolves the caller's organization through public.current_org_id(), which
-- reads the same table. Nothing created that row on sign-up, so a fresh
-- account had no role (the header fell back to "unknown role") and no
-- organization — which made buildings_read_own_org match nothing and left the
-- buildings dropdown empty.
--
-- SECURITY DEFINER because the trigger runs as the signing-up user, who holds
-- no insert policy on profiles. That absence is deliberate: role changes must
-- never be a client-side write, so the row is created server-side instead.
-- The default role is 'viewer' — least privilege, and never null.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_org uuid := '11111111-1111-1111-1111-111111111111';
begin
    -- Sign-ups join the demo organization. It is created here when absent
    -- because auth.users rows are inserted before seed.sql creates the org,
    -- and the profiles FK would otherwise fail during a seed run.
    insert into public.organizations (id, name)
    values (v_org, 'Bellarmine College Preparatory')
    on conflict (id) do nothing;

    insert into public.profiles (id, organization_id, role, display_name)
    values (new.id, v_org, 'viewer', new.email)
    on conflict (id) do nothing;

    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();
