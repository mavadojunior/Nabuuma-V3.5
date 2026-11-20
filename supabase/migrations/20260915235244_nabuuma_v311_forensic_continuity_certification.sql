-- Nabuuma V3.11: forensic continuity certification and exact repair integrity.
-- Historical ledger rows remain immutable. Certification is read-only; repairs remain compensating transactions.

create table if not exists public.network_ledger_forensic_certifications (
  certification_id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  account_id uuid,
  reconciliation_run_id uuid references public.network_reconciliation_runs(id) on delete restrict,
  certification_type text not null check (certification_type in ('business_ledger','account_ledger','repair_integrity','global_chain')),
  status text not null check (status in ('certified','divergent','failed')),
  checked_entry_count integer not null default 0 check (checked_entry_count >= 0),
  balanced boolean not null,
  chain_valid boolean not null,
  repairs_valid boolean not null,
  observed_head_hash text,
  certification_hash text not null,
  certified_at timestamptz not null default now(),
  unique (business_id, account_id, certification_type, certified_at)
);

create table if not exists public.network_ledger_forensic_events (
  event_id uuid primary key default gen_random_uuid(),
  certification_id uuid not null references public.network_ledger_forensic_certifications(certification_id) on delete restrict,
  business_id uuid not null,
  event_type text not null check (event_type in ('certification_created','certification_failed')),
  payload jsonb not null,
  previous_hash text,
  event_hash text not null,
  created_at timestamptz not null default now()
);

create index if not exists network_ledger_forensic_cert_business_idx on public.network_ledger_forensic_certifications(business_id, certified_at desc);
create index if not exists network_ledger_forensic_events_cert_idx on public.network_ledger_forensic_events(certification_id, created_at, event_id);

alter table public.network_ledger_forensic_certifications enable row level security;
alter table public.network_ledger_forensic_events enable row level security;

revoke all on table public.network_ledger_forensic_certifications from anon, authenticated;
revoke all on table public.network_ledger_forensic_events from anon, authenticated;
grant select on table public.network_ledger_forensic_certifications to authenticated;
grant select on table public.network_ledger_forensic_events to authenticated;
grant select on table public.network_ledger_forensic_certifications to service_role;
grant select on table public.network_ledger_forensic_events to service_role;

create policy network_ledger_forensic_cert_authenticated_select
on public.network_ledger_forensic_certifications
for select to authenticated
using (exists (select 1 from public.business_members bm where bm.business_id = network_ledger_forensic_certifications.business_id and bm.user_id = (select auth.uid())));

create policy network_ledger_forensic_events_authenticated_select
on public.network_ledger_forensic_events
for select to authenticated
using (exists (select 1 from public.business_members bm where bm.business_id = network_ledger_forensic_events.business_id and bm.user_id = (select auth.uid())));

-- Append-only forensic evidence.
create or replace function public.v311_forensic_event_guard()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, public, extensions, pg_temp
as $$
begin
  if tg_op <> 'INSERT' then raise exception 'forensic events are immutable'; end if;
  return new;
end;
$$;

drop trigger if exists network_ledger_forensic_events_immutable on public.network_ledger_forensic_events;
create trigger network_ledger_forensic_events_immutable
before update or delete on public.network_ledger_forensic_events
for each row execute function public.v311_forensic_event_guard();

revoke execute on function public.v311_forensic_event_guard() from public, anon, authenticated, service_role;

-- Canonical forensic digest. Uses fully qualified references and deterministic JSONB text.
create or replace function public.v311_forensic_digest(
  p_business_id uuid,
  p_account_id uuid,
  p_certification_type text,
  p_entry_count integer,
  p_balanced boolean,
  p_chain_valid boolean,
  p_repairs_valid boolean,
  p_head_hash text
)
returns text
language sql
immutable
security invoker
set search_path = pg_catalog, public, extensions, pg_temp
as $$
  select encode(extensions.digest(convert_to(
    coalesce(p_business_id::text,'') || ':' ||
    coalesce(p_account_id::text,'') || ':' ||
    coalesce(p_certification_type,'') || ':' ||
    p_entry_count::text || ':' ||
    p_balanced::text || ':' ||
    p_chain_valid::text || ':' ||
    p_repairs_valid::text || ':' ||
    coalesce(p_head_hash,''), 'UTF8'), 'sha256'), 'hex');
$$;

revoke all on function public.v311_forensic_digest(uuid,uuid,text,integer,boolean,boolean,boolean,text) from public, anon, authenticated;
grant execute on function public.v311_forensic_digest(uuid,uuid,text,integer,boolean,boolean,boolean,text) to service_role;

-- Replace V3.10 continuity logic: chain validation is GLOBAL, while balance checks are business/account scoped.
-- This avoids falsely treating the previous global ledger entry from another tenant as a chain break.
create or replace function public.network_check_ledger_continuity(
  p_business_id uuid,
  p_account_id uuid default null,
  p_reconciliation_run_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare
  v_check uuid := gen_random_uuid();
  v_sum bigint := 0;
  v_balance bigint := 0;
  v_delta bigint := 0;
  v_count integer := 0;
  v_chain_valid boolean := true;
  v_head text;
  v_scope_account uuid;
  v_bad_id bigint;
begin
  if current_user <> 'service_role' and current_user <> 'postgres' then raise exception 'service role required'; end if;
  if p_business_id is null then raise exception 'business id required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('nabuuma:v311:continuity:' || p_business_id::text, 3111));

  if p_account_id is null then
    select coalesce(sum(e.debit_minor-e.credit_minor),0), count(*)
      into v_sum,v_count
    from public.financial_ledger_entries e
    where e.business_id=p_business_id;
    select coalesce(sum(a.balance_minor),0) into v_balance
    from public.financial_accounts a where a.business_id=p_business_id;
  else
    select coalesce(sum(e.debit_minor-e.credit_minor),0), count(*)
      into v_sum,v_count
    from public.financial_ledger_entries e
    where e.business_id=p_business_id and e.account_id=p_account_id;
    select a.balance_minor into v_balance
    from public.financial_accounts a
    where a.id=p_account_id and a.business_id=p_business_id;
    if v_balance is null then raise exception 'account not found for business'; end if;
    v_scope_account := p_account_id;
  end if;

  -- The V3.2 ledger is one append-only global chain. Validate every link, then scope the balance test.
  select q.id into v_bad_id
  from (
    select e.id,
           e.previous_entry_hash,
           lag(e.entry_hash) over(order by e.id) as prior_hash
    from public.financial_ledger_entries e
  ) q
  where coalesce(q.previous_entry_hash,'') <> coalesce(q.prior_hash,'')
  order by q.id
  limit 1;
  v_chain_valid := v_bad_id is null;

  select e.entry_hash into v_head
  from public.financial_ledger_entries e order by e.id desc limit 1;

  v_delta := coalesce(v_balance,0)-v_sum;
  insert into public.network_ledger_continuity_checks(
    check_id,business_id,account_id,reconciliation_run_id,ledger_sum_minor,account_balance_minor,delta_minor,
    checked_entry_count,chain_valid,status,observed_head_hash,expected_previous_hash
  ) values (
    v_check,p_business_id,v_scope_account,p_reconciliation_run_id,v_sum,v_balance,v_delta,v_count,
    v_chain_valid,case when v_chain_valid and v_delta=0 then 'clean' else 'divergent' end,
    v_head,case when v_bad_id is null then null else 'chain_break_at:'||v_bad_id::text end
  );
  return v_check;
end;
$$;

revoke all on function public.network_check_ledger_continuity(uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.network_check_ledger_continuity(uuid,uuid,uuid) to service_role;

-- Strengthen V3.10 repair execution: the stored digest must match the persisted repair lines before money moves.
create or replace function public.network_execute_ledger_repair(p_repair_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare
  v_business uuid;
  v_div uuid;
  v_currency text;
  v_amount bigint;
  v_digest text;
  v_recomputed text;
  v_tx uuid := gen_random_uuid();
  v_entries jsonb;
  v_execution_hash text;
  v_prev text;
  v_payload jsonb;
  r record;
begin
  if current_user <> 'service_role' and current_user <> 'postgres' then raise exception 'service role required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('nabuuma:v311:repair:' || p_repair_id::text, 3110));

  select r.business_id,r.divergence_id,r.currency,r.amount_minor,r.repair_digest
    into v_business,v_div,v_currency,v_amount,v_digest
  from public.network_financial_repairs r
  where r.id=p_repair_id
  for update;
  if v_business is null then raise exception 'repair not found'; end if;
  if exists(select 1 from public.network_financial_repairs r where r.id=p_repair_id and (r.executed_at is not null or r.rejected_at is not null)) then raise exception 'repair already finalized'; end if;
  if v_digest is null then raise exception 'ledger repair digest missing'; end if;
  if not exists(select 1 from public.network_financial_repairs r where r.id=p_repair_id and r.repair_type='ledger_continuity') then raise exception 'repair is not a ledger continuity repair'; end if;
  if exists(select 1 from public.network_financial_repairs r where r.id=p_repair_id and r.finality_gate_id is not null)
     and not exists(select 1 from public.network_financial_finality_gates g join public.network_financial_repairs r on r.finality_gate_id=g.gate_id where r.id=p_repair_id and g.state in ('verified','consumed')) then
    raise exception 'linked finality gate is not verified';
  end if;

  select jsonb_agg(jsonb_build_object(
    'business_id',l.business_id,'account_id',l.account_id,'currency',l.currency,
    'debit_minor',l.debit_minor,'credit_minor',l.credit_minor,
    'source_type','financial_repair','source_id',p_repair_id
  ) order by l.sequence_no)
  into v_entries
  from public.network_ledger_repair_lines l where l.repair_id=p_repair_id;

  if jsonb_typeof(v_entries) <> 'array' or jsonb_array_length(v_entries) < 2 then raise exception 'repair lines missing'; end if;
  if (select coalesce(sum(l.debit_minor),0) from public.network_ledger_repair_lines l where l.repair_id=p_repair_id)
     <> (select coalesce(sum(l.credit_minor),0) from public.network_ledger_repair_lines l where l.repair_id=p_repair_id)
     or (select coalesce(sum(l.debit_minor),0) from public.network_ledger_repair_lines l where l.repair_id=p_repair_id) <> v_amount then
    raise exception 'repair lines are not balanced';
  end if;

  v_recomputed := public.v310_canonical_repair_digest(p_repair_id, v_entries);
  if v_recomputed <> v_digest then raise exception 'repair digest mismatch'; end if;

  perform public.v32_append_ledger_transaction(v_tx,v_entries);

  v_execution_hash := encode(extensions.digest(convert_to(
    p_repair_id::text || ':' || v_tx::text || ':' || v_digest || ':' || v_amount::text || ':' || v_currency,
    'UTF8'),'sha256'),'hex');

  update public.network_financial_repairs
  set executed_at=now(),execution_hash=v_execution_hash,ledger_transaction_id=v_tx
  where id=p_repair_id;
  update public.network_financial_divergences
  set state='repaired',resolved_at=now() where id=v_div;

  select e.event_hash into v_prev from public.network_financial_repair_events e
  where e.repair_id=p_repair_id order by e.created_at desc,e.id desc limit 1;
  v_payload := jsonb_build_object('execution_hash',v_execution_hash,'ledger_transaction_id',v_tx,'amount_minor',v_amount,'currency',v_currency,'repair_digest',v_digest);
  insert into public.network_financial_repair_events(repair_id,business_id,event_type,payload,previous_hash,event_hash)
  values(p_repair_id,v_business,'repair_executed',v_payload,v_prev,public.v39_hash_repair_event(p_repair_id,'repair_executed',v_payload,v_prev));
  return v_tx;
end;
$$;

revoke all on function public.network_execute_ledger_repair(uuid) from public, anon, authenticated;
grant execute on function public.network_execute_ledger_repair(uuid) to service_role;

-- Certification boundary. This never mutates financial balances and never creates a repair.
create or replace function public.network_certify_ledger_integrity(
  p_business_id uuid,
  p_account_id uuid default null,
  p_reconciliation_run_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare
  v_cert uuid := gen_random_uuid();
  v_count integer := 0;
  v_sum bigint := 0;
  v_balance bigint := 0;
  v_delta bigint := 0;
  v_chain boolean := true;
  v_repairs boolean := true;
  v_head text;
  v_status text;
  v_hash text;
  v_bad bigint;
  v_account uuid;
  v_payload jsonb;
  v_prev text;
begin
  if current_user <> 'service_role' and current_user <> 'postgres' then raise exception 'service role required'; end if;
  if p_business_id is null then raise exception 'business id required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('nabuuma:v311:cert:' || p_business_id::text,3112));

  if p_account_id is null then
    select coalesce(sum(e.debit_minor-e.credit_minor),0),count(*) into v_sum,v_count from public.financial_ledger_entries e where e.business_id=p_business_id;
    select coalesce(sum(a.balance_minor),0) into v_balance from public.financial_accounts a where a.business_id=p_business_id;
  else
    select coalesce(sum(e.debit_minor-e.credit_minor),0),count(*) into v_sum,v_count from public.financial_ledger_entries e where e.business_id=p_business_id and e.account_id=p_account_id;
    select a.balance_minor into v_balance from public.financial_accounts a where a.id=p_account_id and a.business_id=p_business_id;
    if v_balance is null then raise exception 'account not found for business'; end if;
    v_account := p_account_id;
  end if;

  select q.id into v_bad from (
    select e.id,e.previous_entry_hash,lag(e.entry_hash) over(order by e.id) prior_hash from public.financial_ledger_entries e
  ) q where coalesce(q.previous_entry_hash,'') <> coalesce(q.prior_hash,'') order by q.id limit 1;
  v_chain := v_bad is null;

  if exists (
    select 1 from public.network_financial_repairs r
    where r.business_id=p_business_id and r.repair_type='ledger_continuity'
      and r.executed_at is not null
      and (r.repair_digest is null or r.execution_hash is null or r.ledger_transaction_id is null)
  ) then v_repairs := false; end if;

  select e.entry_hash into v_head from public.financial_ledger_entries e order by e.id desc limit 1;
  v_delta := coalesce(v_balance,0)-v_sum;
  v_status := case when v_delta=0 and v_chain and v_repairs then 'certified' else 'divergent' end;
  v_hash := public.v311_forensic_digest(p_business_id,v_account,case when p_account_id is null then 'business_ledger' else 'account_ledger' end,v_count,v_delta=0,v_chain,v_repairs,v_head);

  insert into public.network_ledger_forensic_certifications(
    certification_id,business_id,account_id,reconciliation_run_id,certification_type,status,
    checked_entry_count,balanced,chain_valid,repairs_valid,observed_head_hash,certification_hash
  ) values(v_cert,p_business_id,v_account,p_reconciliation_run_id,case when p_account_id is null then 'business_ledger' else 'account_ledger' end,
           v_status,v_count,v_delta=0,v_chain,v_repairs,v_head,v_hash);

  select e.event_hash into v_prev from public.network_ledger_forensic_events e where e.certification_id=v_cert order by e.created_at desc,e.event_id desc limit 1;
  v_payload := jsonb_build_object('status',v_status,'checked_entry_count',v_count,'balanced',v_delta=0,'chain_valid',v_chain,'repairs_valid',v_repairs,'observed_head_hash',v_head,'certification_hash',v_hash);
  insert into public.network_ledger_forensic_events(certification_id,business_id,event_type,payload,previous_hash,event_hash)
  values(v_cert,p_business_id,case when v_status='certified' then 'certification_created' else 'certification_failed' end,v_payload,v_prev,
         encode(extensions.digest(convert_to(v_cert::text||':'||v_payload::text||':'||coalesce(v_prev,''),'UTF8'),'sha256'),'hex'));
  return v_cert;
end;
$$;

revoke all on function public.network_certify_ledger_integrity(uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.network_certify_ledger_integrity(uuid,uuid,uuid) to service_role;

-- Final ACL/RLS hardening for the new certification boundary.
revoke insert, update, delete on table public.network_ledger_forensic_certifications from service_role;
revoke insert, update, delete on table public.network_ledger_forensic_events from service_role;
revoke execute on function public.network_certify_ledger_integrity(uuid,uuid,uuid) from public, anon, authenticated;
revoke execute on function public.network_check_ledger_continuity(uuid,uuid,uuid) from public, anon, authenticated;
revoke execute on function public.network_execute_ledger_repair(uuid) from public, anon, authenticated;
