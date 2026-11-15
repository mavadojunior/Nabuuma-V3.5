begin;
alter table public.network_financial_finality_gates drop constraint if exists network_financial_finality_gates_check;
alter table public.network_financial_finality_gates add constraint network_financial_finality_gates_check check (state not in ('verified','consumed') or blocking_reason is null);
commit;