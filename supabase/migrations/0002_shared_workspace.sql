-- Shared workspace and audit metadata for the live accounting application.
-- Safe to run after 0001_initial.sql: existing rows are assigned to one workspace
-- before the new NOT NULL constraints and policies are enabled.
create table if not exists public.workspaces (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  admin_email text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.workspace_members (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  email text not null,
  display_name text,
  role text not null default 'member' check (role in ('admin', 'member')),
  status text not null default 'active' check (status in ('active', 'disabled', 'invited')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workspace_id, email)
);

create unique index if not exists workspace_members_user_idx
  on public.workspace_members (workspace_id, user_id) where user_id is not null;

alter table public.transactions add column if not exists workspace_id uuid references public.workspaces(id);
alter table public.suppliers add column if not exists workspace_id uuid references public.workspaces(id);
alter table public.products add column if not exists workspace_id uuid references public.workspaces(id);
alter table public.transactions add column if not exists created_by uuid references auth.users(id);
alter table public.transactions add column if not exists updated_by uuid references auth.users(id);

insert into public.workspaces (slug, name, admin_email)
values ('shop-accounting', 'ร้านค้าสวัสดิการ', 'wrkshop@wrk.ac.th')
on conflict (slug) do nothing;

do $$
declare wid uuid;
begin
  select id into wid from public.workspaces where slug = 'shop-accounting';

  insert into public.workspace_members (workspace_id, user_id, email, display_name, role, status)
  select wid, u.id, coalesce(u.email, u.id::text),
         coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name'),
         case when lower(u.email) = 'wrkshop@wrk.ac.th' then 'admin' else 'member' end,
         'active'
  from auth.users u
  where u.email is not null
    and (lower(u.email) = 'wrkshop@wrk.ac.th' or lower(u.email) like '%@wrk.ac.th')
  on conflict (workspace_id, email) do update set
    user_id = excluded.user_id,
    display_name = coalesce(excluded.display_name, workspace_members.display_name),
    role = case when lower(excluded.email) = 'wrkshop@wrk.ac.th' then 'admin' else workspace_members.role end,
    status = 'active', updated_at = now();

  insert into public.workspace_members (workspace_id, user_id, email, role, status)
  select distinct wid, t.user_id, coalesce(u.email, t.user_id::text), 'member', 'active'
  from public.transactions t left join auth.users u on u.id = t.user_id
  where t.user_id is not null
  on conflict (workspace_id, email) do update set user_id = excluded.user_id, status = 'active', updated_at = now();

  update public.transactions set workspace_id = wid, created_by = coalesce(created_by, user_id), updated_by = coalesce(updated_by, user_id) where workspace_id is null;
  update public.suppliers set workspace_id = wid where workspace_id is null;
  update public.products set workspace_id = wid where workspace_id is null;
end $$;

alter table public.transactions alter column workspace_id set not null;
alter table public.suppliers alter column workspace_id set not null;
alter table public.products alter column workspace_id set not null;

create index if not exists transactions_workspace_date_idx on public.transactions (workspace_id, transaction_date desc);
create index if not exists suppliers_workspace_name_idx on public.suppliers (workspace_id, supplier_name);
create index if not exists products_workspace_name_idx on public.products (workspace_id, product_name);

create or replace function public.is_workspace_member(target_workspace uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select exists (
  select 1 from public.workspace_members m
  where m.workspace_id = target_workspace and m.user_id = auth.uid() and m.status = 'active'
); $$;

create or replace function public.is_workspace_admin(target_workspace uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select exists (
  select 1 from public.workspace_members m
  where m.workspace_id = target_workspace and m.user_id = auth.uid() and m.role = 'admin' and m.status = 'active'
) or exists (
  select 1 from public.workspaces w
  where w.id = target_workspace and lower(w.admin_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
); $$;

alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;

drop policy if exists workspace_select_member on public.workspaces;
create policy workspace_select_member on public.workspaces for select using (public.is_workspace_member(id) or lower(admin_email) = lower(coalesce(auth.jwt() ->> 'email', '')));
drop policy if exists workspace_members_select on public.workspace_members;
create policy workspace_members_select on public.workspace_members for select using (user_id = auth.uid() or public.is_workspace_admin(workspace_id));
drop policy if exists workspace_members_admin_write on public.workspace_members;
create policy workspace_members_admin_write on public.workspace_members for all using (public.is_workspace_admin(workspace_id)) with check (public.is_workspace_admin(workspace_id));

drop policy if exists transactions_own on public.transactions;
drop policy if exists transactions_workspace on public.transactions;
create policy transactions_workspace on public.transactions for all using (public.is_workspace_member(workspace_id)) with check (public.is_workspace_member(workspace_id));
drop policy if exists suppliers_own on public.suppliers;
drop policy if exists suppliers_workspace on public.suppliers;
create policy suppliers_workspace on public.suppliers for all using (public.is_workspace_member(workspace_id)) with check (public.is_workspace_member(workspace_id));
drop policy if exists products_own on public.products;
drop policy if exists products_workspace on public.products;
create policy products_workspace on public.products for all using (public.is_workspace_member(workspace_id)) with check (public.is_workspace_member(workspace_id));

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
declare wid uuid; invited_id uuid;
begin
  insert into public.profiles (id, email, display_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'))
  on conflict (id) do update set email = excluded.email, display_name = coalesce(excluded.display_name, profiles.display_name), updated_at = now();
  select id into wid from public.workspaces where slug = 'shop-accounting';
  select id into invited_id from public.workspace_members where workspace_id = wid and lower(email) = lower(new.email) limit 1;
  if invited_id is not null then
    update public.workspace_members set user_id = new.id, status = 'active', updated_at = now() where id = invited_id;
  elsif lower(new.email) like '%@wrk.ac.th' then
    insert into public.workspace_members (workspace_id, user_id, email, display_name, role, status)
    values (wid, new.id, new.email, coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'), 'member', 'active')
    on conflict (workspace_id, email) do update set user_id = excluded.user_id, status = 'active', updated_at = now();
  end if;
  return new;
end;
$$;
