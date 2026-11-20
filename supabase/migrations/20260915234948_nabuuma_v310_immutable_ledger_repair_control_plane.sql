begin;

create table if not exists public.network_ledger_continuity_checks (
  check_id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  account_id uuid,
  reconciliation_run_id uuid references public.network_reconciliation_runs(id) on delete restrict,
  ledger_sum_minor bigint not null,
  account_balance_minor bigint,
  delta_minor bigint not null,
  checked_entry_count integer not null check (checked_entry_count >= 0),
  chain_valid boolean not null,
  status text not null check (status in ('clean','divergent')),
  observed_head_hash text,
  expected_previous_hash text,
  checked_at timestamptz not null default now(),
  constraint network_ledger_continuity_delta_ck check (delta_minor = coalesce(account_balance_minor, ledger_sum_minor) - ledger_sum_minor)
);

create index if not exists network_ledger_continuity_business_idx
  on public.network_ledger_continuity_checks(business_id, checked_at desc);
create index if not exists network_ledger_continuity_account_idx
  on public.network_ledger_continuity_checks(account_id, checked_at desc);

create table if not exists public.network_ledger_repair_lines (
  repair_line_id uuid primary key default gen_random_uuid(),
  repair_id uuid not null references public.network_financial_repairs(id) on delete restrict,
  business_id uuid not null,
  sequence_no integer not null check (sequence_no > 0),
  account_id uuid not null references public.financial_accounts(id) on delete restrict,
  currency text not null,
  debit_minor bigint not null default 0 check (debit_minor >= 0),
  credit_minor bigint not null default 0 check (credit_minor >= 0),
  source_type text not null default 'financial_repair',
  created_at timestamptz not null default now(),
  constraint network_ledger_repair_line_side_ck check (((debit_minor > 0)::integer + (credit_minor > 0)::integer) = 1),
  unique (repair_id, sequence_no)
);

create index if not exists network_ledger_repair_lines_repair_idx
  on public.network_ledger_repair_lines(repair_id, sequence_no);
create index if not exists network_ledger_repair_lines_account_idx
  on public.network_ledger_repair_lines(account_id);

alter table public.network_financial_repairs
  add column if not exists ledger_transaction_id uuid,
  add column if not exists repair_digest text,
  add column if not exists finality_gate_id uuid references public.network_financial_finality_gates(gate_id) on delete restrict;

create unique index if not exists network_financial_repairs_ledger_tx_idx
  on public.network_financial_repairs(ledger_transaction_id)
  where ledger_transaction_id is not null;
create unique index if not exists network_financial_repairs_digest_idx
  on public.network_financial_repairs(repair_digest)
  where repair_digest is not null;

alter table public.network_ledger_continuity_checks enable row level security;
alter table public.network_ledger_repair_lines enable row level security;

drop policy if exists network_ledger_continuity_authenticated_select on public.network_ledger_continuity_checks;
create policy network_ledger_continuity_authenticated_select
on public.network_ledger_continuity_checks
for select to authenticated
using (exists (
  select 1 from public.business_members bm
  where bm.business_id = network_ledger_continuity_checks.business_id
    and bm.user_id = (select auth.uid())
));

drop policy if exists network_ledger_repair_lines_authenticated_select on public.network_ledger_repair_lines;
create policy network_ledger_repair_lines_authenticated_select
on public.network_ledger_repair_lines
for select to authenticated
using (exists (
  select 1 from public.business_members bm
  where bm.business_id = network_ledger_repair_lines.business_id
    and bm.user_id = (select auth.uid())
));

revoke all on table public.network_ledger_continuity_checks from anon, authenticated;
grant select on table public.network_ledger_continuity_checks to authenticated;
revoke all on table public.network_ledger_repair_lines from anon, authenticated, service_role;
grant select on table public.network_ledger_repair_lines to authenticated;
grant select on table public.network_ledger_repair_lines to service_role;
revoke insert, update, delete on table public.network_ledger_continuity_checks from anon, authenticated, service_role;

create or replace function public.v310_canonical_repair_digest(p_repair_id uuid, p_lines jsonb)
returns text
language sql
immutable
security invoker
set search_path = pg_catalog, public, extensions, pg_temp
as $$
  select encode(extensions.digest(
    convert_to(coalesce(p_repair_id::text,'') || ':' || coalesce(p_lines::text,'[]'), 'UTF8'),
    'sha256'
  ), 'hex');
$$;

create or replace function public.network_authorize_ledger_repair(
  p_divergence_id uuid,
  p_amount_minor bigint,
  p_currency text,
  p_authorized_by uuid,
  p_second_authorizer uuid,
  p_reason text,
  p_lines jsonb,
  p_finality_gate_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare
  v_repair uuid;
  v_business uuid;
  v_currency text;
  v_sum_debit bigint := 0;
  v_sum_credit bigint := 0;
  v_count integer := 0;
  r jsonb;
  v_account uuid;
  v_line_currency text;
  v_debit bigint;
  v_credit bigint;
  v_digest text;
begin
  if current_user <> 'service_role' and current_user <> 'postgres' then
    raise exception 'service role required';
  end if;
  if p_amount_minor <= 0 or p_currency is null or length(p_currency) <> 3 then
    raise exception 'invalid repair amount or currency';
  end if;
  if p_authorized_by is null or p_second_authorizer is null or p_authorized_by = p_second_authorizer then
    raise exception 'distinct authorizers required';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'ledger repair requires at least two lines';
  end if;

  select d.business_id into v_business
  from public.network_financial_divergences d
  where d.id = p_divergence_id
    and d.state in ('open','acknowledged')
  for update;
  if v_business is null then raise exception 'divergence not found or not repairable'; end if;

  if p_finality_gate_id is not null then
    if not exists (
      select 1 from public.network_financial_finality_gates g
      where g.gate_id = p_finality_gate_id
        and g.state in ('verified','consumed')
    ) then
      raise exception 'finality gate is not verified';
    end if;
  end if;

  for r in select value from jsonb_array_elements(p_lines) loop
    v_account := (r->>'account_id')::uuid;
    v_line_currency := r->>'currency';
    v_debit := coalesce((r->>'debit_minor')::bigint,0);
    v_credit := coalesce((r->>'credit_minor')::bigint,0);
    if v_account is null or v_line_currency <> p_currency then raise exception 'repair line account/currency mismatch'; end if;
    if ((v_debit > 0)::integer + (v_credit > 0)::integer) <> 1 then raise exception 'repair line must contain exactly one positive side'; end if;
    if v_debit < 0 or v_credit < 0 then raise exception 'negative repair amount'; end if;
    if not exists (
      select 1 from public.financial_accounts a
      where a.id = v_account and a.business_id = v_business and a.currency = p_currency and a.active
    ) then raise exception 'repair account does not belong to business/currency'; end if;
    v_sum_debit := v_sum_debit + v_debit;
    v_sum_credit := v_sum_credit + v_credit;
    v_count := v_count + 1;
  end loop;

  if v_count < 2 or v_sum_debit <> v_sum_credit or v_sum_debit <> p_amount_minor then
    raise exception 'repair lines are not balanced to authorized amount';
  end if;

  v_repair := public.network_authorize_financial_repair(
    p_divergence_id,
    'ledger_continuity',
    p_amount_minor,
    p_currency,
    p_authorized_by,
    p_second_authorizer,
    p_reason,
    public.v310_canonical_repair_digest(p_divergence_id, p_lines)
  );

  v_digest := public.v310_canonical_repair_digest(v_repair, p_lines);
  update public.network_financial_repairs
  set repair_digest = v_digest,
      finality_gate_id = p_finality_gate_id
  where id = v_repair;

  for r in select value from jsonb_array_elements(p_lines) loop
    insert into public.network_ledger_repair_lines(
      repair_id,business_id,sequence_no,account_id,currency,debit_minor,credit_minor,source_type
    ) values (
      v_repair,v_business,(r->>'sequence_no')::integer,(r->>'account_id')::uuid,
      r->>'currency',coalesce((r->>'debit_minor')::bigint,0),coalesce((r->>'credit_minor')::bigint,0),
      coalesce(nullif(r->>'source_type',''),'financial_repair')
    );
  end loop;

  if exists (
    select 1 from public.network_ledger_repair_lines l
    where l.repair_id=v_repair
    group by l.repair_id
    having count(*) <> v_count
  ) then raise exception 'repair line count mismatch'; end if;

  return v_repair;
end;
$$;

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
  v_tx uuid := gen_random_uuid();
  v_entries jsonb;
  v_execution_hash text;
  v_prev text;
  v_payload jsonb;
  r record;
begin
  if current_user <> 'service_role' and current_user <> 'postgres' then
    raise exception 'service role required';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('nabuuma:v310:repair:' || p_repair_id::text, 3100));

  select r.business_id,r.divergence_id,r.currency,r.amount_minor,r.repair_digest
    into v_business,v_div,v_currency,v_amount,v_digest
  from public.network_financial_repairs r
  where r.id=p_repair_id
  for update;
  if v_business is null then raise exception 'repair not found'; end if;
  if exists(select 1 from public.network_financial_repairs r where r.id=p_repair_id and (r.executed_at is not null or r.rejected_at is not null)) then
    raise exception 'repair already finalized';
  end if;
  if v_digest is null then raise exception 'ledger repair digest missing'; end if;

  if not exists(select 1 from public.network_financial_repairs r where r.id=p_repair_id and r.repair_type='ledger_continuity') then
    raise exception 'repair is not a ledger continuity repair';
  end if;
  if exists(select 1 from public.network_financial_repairs r where r.id=p_repair_id and r.finality_gate_id is not null)
     and not exists(select 1 from public.network_financial_finality_gates g join public.network_financial_repairs r on r.finality_gate_id=g.gate_id where r.id=p_repair_id and g.state in ('verified','consumed')) then
    raise exception 'linked finality gate is not verified';
  end if;

  select jsonb_agg(jsonb_build_object(
    'business_id',l.business_id,
    'account_id',l.account_id,
    'currency',l.currency,
    'debit_minor',l.debit_minor,
    'credit_minor',l.credit_minor,
    'source_type','financial_repair',
    'source_id',p_repair_id
  ) order by l.sequence_no)
  into v_entries
  from public.network_ledger_repair_lines l
  where l.repair_id=p_repair_id;

  if jsonb_typeof(v_entries) <> 'array' or jsonb_array_length(v_entries) < 2 then raise exception 'repair lines missing'; end if;
  if (select coalesce(sum(l.debit_minor),0) from public.network_ledger_repair_lines l where l.repair_id=p_repair_id)
     <> (select coalesce(sum(l.credit_minor),0) from public.network_ledger_repair_lines l where l.repair_id=p_repair_id)
     or (select coalesce(sum(l.debit_minor),0) from public.network_ledger_repair_lines l where l.repair_id=p_repair_id) <> v_amount then
    raise exception 'repair lines are not balanced';
  end if;

  perform public.v32_append_ledger_transaction(v_tx,v_entries);

  v_execution_hash := encode(extensions.digest(convert_to(
    p_repair_id::text || ':' || v_tx::text || ':' || v_digest || ':' || v_amount::text || ':' || v_currency,
    'UTF8'),'sha256'),'hex');

  update public.network_financial_repairs
  set executed_at=now(), execution_hash=v_execution_hash, ledger_transaction_id=v_tx
  where id=p_repair_id;

  update public.network_financial_divergences
  set state='repaired', resolved_at=now()
  where id=v_div;

  select e.event_hash into v_prev
  from public.network_financial_repair_events e
  where e.repair_id=p_repair_id
  order by e.created_at desc,e.id desc limit 1;

  v_payload := jsonb_build_object('execution_hash',v_execution_hash,'ledger_transaction_id',v_tx,'amount_minor',v_amount,'currency',v_currency,'repair_digest',v_digest);
  insert into public.network_financial_repair_events(repair_id,business_id,event_type,payload,previous_hash,event_hash)
  values(p_repair_id,v_business,'repair_executed',v_payload,v_prev,public.v39_hash_repair_event(p_repair_id,'repair_executed',v_payload,v_prev));

  return v_tx;
end;
$$;

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
  v_count integer;
  v_sum bigint;
  v_balance bigint;
  v_delta bigint;
  v_chain_valid boolean;
  v_head text;
  v_prev text;
  v_account uuid;
begin
  if current_user <> 'service_role' and current_user <> 'postgres' then raise exception 'service role required'; end if;
  if p_business_id is null then raise exception 'business id required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('nabuuma:v310:continuity:' || p_business_id::text,3101));

  if p_account_id is null then
    select coalesce(sum(e.debit_minor-e.credit_minor),0), count(*) into v_sum,v_count
    from public.financial_ledger_entries e where e.business_id=p_business_id;
    select coalesce(sum(a.balance_minor),0) into v_balance from public.financial_accounts a where a.business_id=p_business_id;
    v_account := null;
  else
    select coalesce(sum(e.debit_minor-e.credit_minor),0), count(*) into v_sum,v_count
    from public.financial_ledger_entries e where e.business_id=p_business_id and e.account_id=p_account_id;
    select a.balance_minor into v_balance from public.financial_accounts a where a.id=p_account_id and a.business_id=p_business_id;
    if v_balance is null then raise exception 'account not found for business'; end if;
    v_account := p_account_id;
  end if;

  select count(*)=0 into v_chain_valid
  from (
    select e.id,e.previous_entry_hash,lag(e.entry_hash) over(order by e.id) as prior_hash
    from public.financial_ledger_entries e
    where e.business_id=p_business_id
  ) q
  where coalesce(q.previous_entry_hash,'') <> coalesce(q.prior_hash,'');

  select e.entry_hash into v_head from public.financial_ledger_entries e where e.business_id=p_business_id order by e.id desc limit 1;
  select e.previous_entry_hash into v_prev from public.financial_ledger_entries e where e.business_id=p_business_id order by e.id desc limit 1;

  v_delta := coalesce(v_balance,v_sum)-v_sum;
  insert into public.network_ledger_continuity_checks(
    check_id,business_id,account_id,reconciliation_run_id,ledger_sum_minor,account_balance_minor,delta_minor,
    checked_entry_count,chain_valid,status,observed_head_hash,expected_previous_hash
  ) values (
    v_check,p_business_id,v_account,p_reconciliation_run_id,v_sum,v_balance,v_delta,v_count,
    coalesce(v_chain_valid,true),
    case when coalesce(v_chain_valid,true) and v_delta=0 then 'clean' else 'divergent' end,
    v_head,v_prev
  );
  return v_check;
end;
$$;

create or replace function public.v32_is_trusted_executor()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
  select current_user = 'postgres' or coalesce(auth.role(),'') = 'service_role';
$$;

create or replace function public.v32_append_ledger_transaction(p_transaction_id uuid, p_entries jsonb)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare
  r jsonb;
  v_debit bigint;
  v_credit bigint;
  v_business uuid;
  v_account uuid;
  v_currency text;
  v_sum_d bigint := 0;
  v_sum_c bigint := 0;
  v_count integer := 0;
begin
  if not public.v32_is_trusted_executor() then raise exception 'trusted executor required'; end if;
  if p_transaction_id is null or jsonb_typeof(p_entries) <> 'array' or jsonb_array_length(p_entries) < 2 then raise exception 'invalid ledger transaction payload'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('nabuuma:v32:ledger-chain',3202));
  for r in select value from pg_catalog.jsonb_array_elements(p_entries) loop
    v_debit := coalesce((r->>'debit_minor')::bigint,0);
    v_credit := coalesce((r->>'credit_minor')::bigint,0);
    v_business := (r->>'business_id')::uuid;
    v_account := (r->>'account_id')::uuid;
    v_currency := r->>'currency';
    if v_business is null or v_account is null or v_currency is null or pg_catalog.length(v_currency) <> 3 then raise exception 'invalid ledger entry'; end if;
    if ((v_debit > 0)::integer + (v_credit > 0)::integer) <> 1 then raise exception 'ledger entry must contain exactly one positive side'; end if;
    if v_debit < 0 or v_credit < 0 then raise exception 'negative ledger amount'; end if;
    if not exists (select 1 from public.financial_accounts a where a.id=v_account and a.business_id=v_business and a.currency=v_currency and a.active) then raise exception 'ledger account does not belong to business/currency'; end if;
    v_sum_d := v_sum_d + v_debit; v_sum_c := v_sum_c + v_credit; v_count := v_count + 1;
    insert into public.financial_ledger_entries(transaction_id,business_id,account_id,currency,debit_minor,credit_minor,source_type,source_id)
    values(p_transaction_id,v_business,v_account,v_currency,v_debit,v_credit,r->>'source_type',nullif(r->>'source_id','')::uuid);
  end loop;
  if v_count < 2 or v_sum_d <> v_sum_c then raise exception 'unbalanced ledger transaction'; end if;
  return p_transaction_id;
end;
$$;

revoke all on function public.network_authorize_ledger_repair(uuid,bigint,text,uuid,uuid,text,jsonb,uuid) from public, anon, authenticated;
grant execute on function public.network_authorize_ledger_repair(uuid,bigint,text,uuid,uuid,text,jsonb,uuid) to service_role;
revoke all on function public.network_execute_ledger_repair(uuid) from public, anon, authenticated;
grant execute on function public.network_execute_ledger_repair(uuid) to service_role;
revoke all on function public.network_check_ledger_continuity(uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.network_check_ledger_continuity(uuid,uuid,uuid) to service_role;
revoke all on function public.v310_canonical_repair_digest(uuid,jsonb) from public, anon, authenticated;
grant execute on function public.v310_canonical_repair_digest(uuid,jsonb) to service_role;

create or replace function public.v310_ledger_repair_lines_immutable_guard()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, public, extensions, pg_temp
as $$
begin
  raise exception 'network ledger repair lines are immutable';
end;
$$;

drop trigger if exists network_ledger_repair_lines_no_update on public.network_ledger_repair_lines;
create trigger network_ledger_repair_lines_no_update
before update or delete on public.network_ledger_repair_lines
for each row execute function public.v310_ledger_repair_lines_immutable_guard();

commit;