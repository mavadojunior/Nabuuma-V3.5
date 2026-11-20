begin;
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
  ) q
  where coalesce(q.previous_entry_hash,'') <> coalesce(q.prior_hash,'');

  select e.entry_hash into v_head from public.financial_ledger_entries e order by e.id desc limit 1;
  select e.previous_entry_hash into v_prev from public.financial_ledger_entries e order by e.id desc limit 1;

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
commit;