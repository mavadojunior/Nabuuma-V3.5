create extension if not exists pgcrypto;

create table if not exists public.network_reconciliation_runs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  scope_type text not null check (scope_type in ('settlement_batch','route','financial_account','business')),
  scope_id uuid,
  status text not null default 'running' check (status in ('running','clean','divergent','failed','repaired')),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  observed_hash text,
  expected_hash text,
  divergence_count integer not null default 0 check (divergence_count >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.network_financial_divergences (
  id uuid primary key default gen_random_uuid(),
  reconciliation_run_id uuid not null references public.network_reconciliation_runs(id),
  business_id uuid not null,
  divergence_type text not null check (divergence_type in ('ledger_imbalance','settlement_mismatch','route_mismatch','finality_mismatch','hash_mismatch','orphaned_record')),
  source_table text not null,
  source_id uuid,
  expected_minor bigint,
  observed_minor bigint,
  expected_hash text,
  observed_hash text,
  state text not null default 'open' check (state in ('open','acknowledged','repair_authorized','repaired','rejected')),
  detected_at timestamptz not null default now(),
  resolved_at timestamptz,
  unique (reconciliation_run_id, divergence_type, source_table, source_id)
);

create table if not exists public.network_financial_repairs (
  id uuid primary key default gen_random_uuid(),
  reconciliation_run_id uuid not null references public.network_reconciliation_runs(id),
  divergence_id uuid not null references public.network_financial_divergences(id),
  business_id uuid not null,
  repair_type text not null check (repair_type in ('ledger_continuity','settlement_state','route_state','finality_state','orphan_reconciliation')),
  amount_minor bigint,
  currency text,
  authorization_digest text not null unique,
  reason text not null,
  authorized_by uuid not null,
  second_authorizer uuid,
  authorized_at timestamptz not null default now(),
  executed_at timestamptz,
  rejected_at timestamptz,
  execution_hash text,
  check (second_authorizer is null or second_authorizer <> authorized_by)
);

create table if not exists public.network_financial_repair_events (
  id uuid primary key default gen_random_uuid(),
  repair_id uuid not null references public.network_financial_repairs(id),
  business_id uuid not null,
  event_type text not null check (event_type in ('repair_authorized','repair_executed','repair_rejected')),
  payload jsonb not null default '{}'::jsonb,
  previous_hash text,
  event_hash text not null,
  created_at timestamptz not null default now()
);

create index if not exists network_reconciliation_runs_business_idx on public.network_reconciliation_runs(business_id, started_at desc);
create index if not exists network_financial_divergences_business_state_idx on public.network_financial_divergences(business_id, state);
create index if not exists network_financial_repairs_divergence_idx on public.network_financial_repairs(divergence_id);
create index if not exists network_financial_repair_events_repair_idx on public.network_financial_repair_events(repair_id, created_at);

alter table public.network_reconciliation_runs enable row level security;
alter table public.network_financial_divergences enable row level security;
alter table public.network_financial_repairs enable row level security;
alter table public.network_financial_repair_events enable row level security;

create policy network_reconciliation_runs_member_select on public.network_reconciliation_runs for select to authenticated using (exists (select 1 from public.business_members bm where bm.business_id = network_reconciliation_runs.business_id and bm.user_id = (select auth.uid())));
create policy network_financial_divergences_member_select on public.network_financial_divergences for select to authenticated using (exists (select 1 from public.business_members bm where bm.business_id = network_financial_divergences.business_id and bm.user_id = (select auth.uid())));
create policy network_financial_repairs_member_select on public.network_financial_repairs for select to authenticated using (exists (select 1 from public.business_members bm where bm.business_id = network_financial_repairs.business_id and bm.user_id = (select auth.uid())));
create policy network_financial_repair_events_member_select on public.network_financial_repair_events for select to authenticated using (exists (select 1 from public.business_members bm where bm.business_id = network_financial_repair_events.business_id and bm.user_id = (select auth.uid())));

revoke all on public.network_reconciliation_runs, public.network_financial_divergences, public.network_financial_repairs, public.network_financial_repair_events from anon, authenticated;
grant select on public.network_reconciliation_runs, public.network_financial_divergences, public.network_financial_repairs, public.network_financial_repair_events to authenticated;
revoke insert, update, delete on public.network_reconciliation_runs, public.network_financial_divergences, public.network_financial_repairs, public.network_financial_repair_events from service_role;
grant select on public.network_reconciliation_runs, public.network_financial_divergences, public.network_financial_repairs, public.network_financial_repair_events to service_role;

create or replace function public.v39_hash_repair_event(p_repair_id uuid,p_event_type text,p_payload jsonb,p_previous_hash text)
returns text language sql immutable security invoker set search_path = pg_catalog, public, extensions, pg_temp as $$
  select encode(digest(coalesce(p_repair_id::text,'') || '|' || coalesce(p_event_type,'') || '|' || coalesce(p_payload::text,'{}') || '|' || coalesce(p_previous_hash,''),'sha256'),'hex')
$$;

create or replace function public.network_start_reconciliation(p_business_id uuid,p_scope_type text,p_scope_id uuid default null)
returns uuid language plpgsql security definer set search_path = pg_catalog, public, extensions, pg_temp as $$
declare v_id uuid;
begin
  if current_user <> 'service_role' then raise exception 'service role required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text || ':' || p_scope_type || ':' || coalesce(p_scope_id::text,''),0));
  insert into public.network_reconciliation_runs(business_id,scope_type,scope_id) values(p_business_id,p_scope_type,p_scope_id) returning id into v_id;
  return v_id;
end $$;

create or replace function public.network_record_financial_divergence(p_run_id uuid,p_divergence_type text,p_source_table text,p_source_id uuid,p_expected_minor bigint,p_observed_minor bigint,p_expected_hash text,p_observed_hash text)
returns uuid language plpgsql security definer set search_path = pg_catalog, public, extensions, pg_temp as $$
declare v_id uuid; v_business uuid;
begin
  if current_user <> 'service_role' then raise exception 'service role required'; end if;
  select business_id into v_business from public.network_reconciliation_runs where id=p_run_id for update;
  if v_business is null then raise exception 'reconciliation run not found'; end if;
  insert into public.network_financial_divergences(reconciliation_run_id,business_id,divergence_type,source_table,source_id,expected_minor,observed_minor,expected_hash,observed_hash)
  values(p_run_id,v_business,p_divergence_type,p_source_table,p_source_id,p_expected_minor,p_observed_minor,p_expected_hash,p_observed_hash)
  on conflict (reconciliation_run_id,divergence_type,source_table,source_id) do update set expected_minor=excluded.expected_minor,observed_minor=excluded.observed_minor,expected_hash=excluded.expected_hash,observed_hash=excluded.observed_hash,state='open'
  returning id into v_id;
  update public.network_reconciliation_runs set status='divergent',divergence_count=divergence_count+1 where id=p_run_id;
  return v_id;
end $$;

create or replace function public.network_complete_reconciliation(p_run_id uuid,p_observed_hash text default null,p_expected_hash text default null)
returns text language plpgsql security definer set search_path = pg_catalog, public, extensions, pg_temp as $$
declare v_count integer; v_status text;
begin
  if current_user <> 'service_role' then raise exception 'service role required'; end if;
  select count(*) into v_count from public.network_financial_divergences where reconciliation_run_id=p_run_id and state in ('open','acknowledged','repair_authorized');
  v_status := case when v_count=0 then 'clean' else 'divergent' end;
  update public.network_reconciliation_runs set status=v_status,completed_at=now(),observed_hash=p_observed_hash,expected_hash=p_expected_hash where id=p_run_id;
  return v_status;
end $$;

create or replace function public.network_authorize_financial_repair(p_divergence_id uuid,p_repair_type text,p_amount_minor bigint,p_currency text,p_authorized_by uuid,p_second_authorizer uuid,p_reason text,p_authorization_digest text)
returns uuid language plpgsql security definer set search_path = pg_catalog, public, extensions, pg_temp as $$
declare v_repair uuid; v_business uuid; v_state text;
begin
  if current_user <> 'service_role' then raise exception 'service role required'; end if;
  if p_authorized_by = p_second_authorizer then raise exception 'distinct authorizers required'; end if;
  select business_id,state into v_business,v_state from public.network_financial_divergences where id=p_divergence_id for update;
  if v_business is null then raise exception 'divergence not found'; end if;
  if v_state not in ('open','acknowledged') then raise exception 'divergence is not repairable'; end if;
  insert into public.network_financial_repairs(reconciliation_run_id,divergence_id,business_id,repair_type,amount_minor,currency,authorization_digest,reason,authorized_by,second_authorizer)
  select reconciliation_run_id,p_divergence_id,v_business,p_repair_type,p_amount_minor,p_currency,p_authorization_digest,p_reason,p_authorized_by,p_second_authorizer from public.network_financial_divergences where id=p_divergence_id
  returning id into v_repair;
  update public.network_financial_divergences set state='repair_authorized' where id=p_divergence_id;
  insert into public.network_financial_repair_events(repair_id,business_id,event_type,payload,event_hash)
  values(v_repair,v_business,'repair_authorized',jsonb_build_object('divergence_id',p_divergence_id,'repair_type',p_repair_type,'amount_minor',p_amount_minor),public.v39_hash_repair_event(v_repair,'repair_authorized',jsonb_build_object('divergence_id',p_divergence_id,'repair_type',p_repair_type,'amount_minor',p_amount_minor),null));
  return v_repair;
end $$;

create or replace function public.network_reject_financial_repair(p_repair_id uuid,p_reason text)
returns void language plpgsql security definer set search_path = pg_catalog, public, extensions, pg_temp as $$
declare v_business uuid; v_div uuid; v_prev text; v_payload jsonb; v_hash text;
begin
  if current_user <> 'service_role' then raise exception 'service role required'; end if;
  select business_id,divergence_id into v_business,v_div from public.network_financial_repairs where id=p_repair_id for update;
  if v_business is null then raise exception 'repair not found'; end if;
  update public.network_financial_repairs set rejected_at=now() where id=p_repair_id and executed_at is null and rejected_at is null;
  if not found then raise exception 'repair already finalized'; end if;
  update public.network_financial_divergences set state='rejected',resolved_at=now() where id=v_div;
  select event_hash into v_prev from public.network_financial_repair_events where repair_id=p_repair_id order by created_at desc,id desc limit 1;
  v_payload := jsonb_build_object('reason',p_reason);
  v_hash := public.v39_hash_repair_event(p_repair_id,'repair_rejected',v_payload,v_prev);
  insert into public.network_financial_repair_events(repair_id,business_id,event_type,payload,previous_hash,event_hash) values(p_repair_id,v_business,'repair_rejected',v_payload,v_prev,v_hash);
end $$;

create or replace function public.network_execute_financial_repair(p_repair_id uuid,p_execution_hash text)
returns void language plpgsql security definer set search_path = pg_catalog, public, extensions, pg_temp as $$
declare v_business uuid; v_div uuid; v_prev text; v_payload jsonb; v_hash text;
begin
  if current_user <> 'service_role' then raise exception 'service role required'; end if;
  select business_id,divergence_id into v_business,v_div from public.network_financial_repairs where id=p_repair_id for update;
  if v_business is null then raise exception 'repair not found'; end if;
  if exists(select 1 from public.network_financial_repairs where id=p_repair_id and (executed_at is not null or rejected_at is not null)) then raise exception 'repair already finalized'; end if;
  if p_execution_hash is null or length(p_execution_hash) <> 64 then raise exception 'execution hash required'; end if;
  update public.network_financial_repairs set executed_at=now(),execution_hash=p_execution_hash where id=p_repair_id;
  update public.network_financial_divergences set state='repaired',resolved_at=now() where id=v_div;
  select event_hash into v_prev from public.network_financial_repair_events where repair_id=p_repair_id order by created_at desc,id desc limit 1;
  v_payload := jsonb_build_object('execution_hash',p_execution_hash);
  v_hash := public.v39_hash_repair_event(p_repair_id,'repair_executed',v_payload,v_prev);
  insert into public.network_financial_repair_events(repair_id,business_id,event_type,payload,previous_hash,event_hash) values(p_repair_id,v_business,'repair_executed',v_payload,v_prev,v_hash);
end $$;

revoke execute on function public.v39_hash_repair_event(uuid,text,jsonb,text) from public,anon,authenticated;
revoke execute on function public.network_start_reconciliation(uuid,text,uuid) from public,anon,authenticated;
revoke execute on function public.network_record_financial_divergence(uuid,text,text,uuid,bigint,bigint,text,text) from public,anon,authenticated;
revoke execute on function public.network_complete_reconciliation(uuid,text,text) from public,anon,authenticated;
revoke execute on function public.network_authorize_financial_repair(uuid,text,bigint,text,uuid,uuid,text,text) from public,anon,authenticated;
revoke execute on function public.network_reject_financial_repair(uuid,text) from public,anon,authenticated;
revoke execute on function public.network_execute_financial_repair(uuid,text) from public,anon,authenticated;
grant execute on function public.network_start_reconciliation(uuid,text,uuid) to service_role;
grant execute on function public.network_record_financial_divergence(uuid,text,text,uuid,bigint,bigint,text,text) to service_role;
grant execute on function public.network_complete_reconciliation(uuid,text,text) to service_role;
grant execute on function public.network_authorize_financial_repair(uuid,text,bigint,text,uuid,uuid,text,text) to service_role;
grant execute on function public.network_reject_financial_repair(uuid,text) to service_role;
grant execute on function public.network_execute_financial_repair(uuid,text) to service_role;

create or replace function public.v39_repair_event_immutable_guard()
returns trigger language plpgsql security invoker set search_path = pg_catalog, public, extensions, pg_temp as $$ begin raise exception 'V3.9 repair events are immutable'; end $$;
create trigger v39_repair_event_immutable before update or delete on public.network_financial_repair_events for each row execute function public.v39_repair_event_immutable_guard();
