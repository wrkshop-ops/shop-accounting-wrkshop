-- Access requests for Google accounts that are not yet workspace members.
-- This migration does not send email; notifications remain an explicit provider integration.
create table if not exists public.workspace_access_requests (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  email text not null,
  display_name text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  unique (workspace_id, user_id, status)
);

create index if not exists workspace_access_requests_admin_idx
  on public.workspace_access_requests (workspace_id, status, created_at desc);

alter table public.workspace_access_requests enable row level security;

drop policy if exists access_requests_select on public.workspace_access_requests;
create policy access_requests_select on public.workspace_access_requests
  for select using (user_id = auth.uid() or public.is_workspace_admin(workspace_id));

drop policy if exists access_requests_insert on public.workspace_access_requests;
create policy access_requests_insert on public.workspace_access_requests
  for insert with check (user_id = auth.uid() and status = 'pending');

drop policy if exists access_requests_admin_update on public.workspace_access_requests;
create policy access_requests_admin_update on public.workspace_access_requests
  for update using (public.is_workspace_admin(workspace_id))
  with check (public.is_workspace_admin(workspace_id));

create or replace function public.request_workspace_access(target_slug text, requester_email text, requester_name text default null)
returns public.workspace_access_requests
language plpgsql security definer set search_path = public
as $$
declare wid uuid; result public.workspace_access_requests;
begin
  if auth.uid() is null or lower(coalesce(auth.jwt() ->> 'email', '')) <> lower(trim(requester_email)) then
    raise exception 'อีเมลคำขอไม่ตรงกับบัญชีที่เข้าสู่ระบบ';
  end if;
  select id into wid from public.workspaces where slug = target_slug;
  if wid is null then raise exception 'ไม่พบ Workspace ที่ขอเข้าใช้งาน'; end if;
  insert into public.workspace_access_requests (workspace_id, user_id, email, display_name)
  values (wid, auth.uid(), lower(trim(requester_email)), nullif(trim(requester_name), ''))
  on conflict (workspace_id, user_id, status) do update set email = excluded.email, display_name = excluded.display_name
  returning * into result;
  return result;
end;
$$;

revoke all on function public.request_workspace_access(text, text, text) from public;
grant execute on function public.request_workspace_access(text, text, text) to authenticated;
