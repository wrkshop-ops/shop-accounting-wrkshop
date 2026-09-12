-- Immutable, compact audit history for financial transaction changes.
-- This migration does not alter or delete existing transaction data.

create table if not exists public.transaction_audit_log (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  transaction_id uuid,
  action text not null check (action in ('insert', 'update', 'delete')),
  actor_id uuid,
  actor_email text,
  occurred_at timestamptz not null default now(),
  changed_fields jsonb not null default '{}'::jsonb
);

create index if not exists transaction_audit_workspace_time_idx
  on public.transaction_audit_log (workspace_id, occurred_at desc);
create index if not exists transaction_audit_transaction_time_idx
  on public.transaction_audit_log (workspace_id, transaction_id, occurred_at desc);

alter table public.transaction_audit_log enable row level security;
drop policy if exists transaction_audit_admin_select on public.transaction_audit_log;
create policy transaction_audit_admin_select
  on public.transaction_audit_log for select
  using (public.is_workspace_admin(workspace_id));

grant select on public.transaction_audit_log to authenticated;
revoke insert, update, delete on public.transaction_audit_log from anon, authenticated;

create or replace function public.touch_transaction_updated_at()
returns trigger language plpgsql set search_path = public
as $$
begin
  if new is distinct from old then
    new.updated_at = now();
  end if;
  return new;
end;
$$;

drop trigger if exists transactions_touch_updated_at on public.transactions;
create trigger transactions_touch_updated_at
  before update on public.transactions
  for each row execute procedure public.touch_transaction_updated_at();

create or replace function public.log_transaction_audit()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  old_data jsonb;
  new_data jsonb;
  diff jsonb;
  workspace_key uuid;
  transaction_key uuid;
  action_key text;
begin
  old_data := case when tg_op in ('UPDATE', 'DELETE') then jsonb_build_object(
    'transaction_type', old.transaction_type, 'transaction_date', old.transaction_date,
    'store_name', old.store_name, 'category', old.category, 'item_name', old.item_name,
    'amount', old.amount, 'total', old.total, 'status', old.status,
    'payment_date', old.payment_date, 'note', old.note, 'balance', old.balance
  ) else null end;
  new_data := case when tg_op in ('INSERT', 'UPDATE') then jsonb_build_object(
    'transaction_type', new.transaction_type, 'transaction_date', new.transaction_date,
    'store_name', new.store_name, 'category', new.category, 'item_name', new.item_name,
    'amount', new.amount, 'total', new.total, 'status', new.status,
    'payment_date', new.payment_date, 'note', new.note, 'balance', new.balance
  ) else null end;

  workspace_key := coalesce(new.workspace_id, old.workspace_id);
  transaction_key := coalesce(new.id, old.id);
  action_key := lower(tg_op);

  if tg_op = 'UPDATE' then
    select coalesce(jsonb_object_agg(keys.key, jsonb_build_object(
      'old', old_data -> keys.key, 'new', new_data -> keys.key
    )), '{}'::jsonb)
      into diff
      from jsonb_object_keys(new_data) as keys(key)
     where (old_data -> keys.key) is distinct from (new_data -> keys.key);
  elsif tg_op = 'INSERT' then
    diff := jsonb_build_object('snapshot', new_data);
  else
    diff := jsonb_build_object('snapshot', old_data);
  end if;

  -- Do not create noise for updates that changed only bookkeeping metadata.
  if tg_op = 'UPDATE' and diff = '{}'::jsonb then
    return new;
  end if;

  insert into public.transaction_audit_log
    (workspace_id, transaction_id, action, actor_id, actor_email, changed_fields)
  values
    (workspace_key, transaction_key, action_key, auth.uid(),
     lower(nullif(trim(coalesce(auth.jwt() ->> 'email', '')), '')), diff);
  return coalesce(new, old);
end;
$$;

drop trigger if exists transactions_audit_log on public.transactions;
create trigger transactions_audit_log
  after insert or update or delete on public.transactions
  for each row execute procedure public.log_transaction_audit();
