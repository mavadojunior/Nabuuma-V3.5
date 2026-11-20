begin;

create or replace function public.fta_append_audit_event(
  p_business_id uuid,
  p_event_type text,
  p_entity_type text,
  p_entity_id uuid,
  p_invoice_number bigint,
  p_event_payload jsonb
) returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare v_id bigint; v_prev text; v_hash text;
begin
  if p_business_id is null or length(btrim(p_event_type))=0 or length(btrim(p_entity_type))=0 then
    raise exception 'invalid audit event';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_business_id::text, 0));
  select event_hash into v_prev from public.fta_audit_log
    where business_id=p_business_id order by audit_id desc limit 1;
  v_hash:=encode(extensions.digest(convert_to(
    p_business_id::text||':'||p_event_type||':'||p_entity_type||':'||coalesce(p_entity_id::text,'')||':'||coalesce(p_invoice_number::text,'')||':'||coalesce(p_event_payload::text,'')||':'||coalesce(v_prev,''),'UTF8'),'sha256'),'hex');
  insert into public.fta_audit_log(business_id,event_type,entity_type,entity_id,invoice_number,event_payload,previous_hash,event_hash,created_by)
  values(p_business_id,p_event_type,p_entity_type,p_entity_id,p_invoice_number,coalesce(p_event_payload,'{}'::jsonb),v_prev,v_hash,auth.uid())
  returning audit_id into v_id;
  return v_id;
end $$;

create or replace function public.gcc_residency_append(
  p_business_id uuid, p_country_code text, p_jurisdiction text, p_residency_class text,
  p_effective_from timestamptz, p_effective_to timestamptz, p_evidence_hash text
) returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare v_id uuid; v_prev text; v_hash text;
begin
  if p_business_id is null or p_country_code not in('AE','SA','BH','KW','OM','QA') or length(btrim(p_jurisdiction))=0 or length(btrim(p_residency_class))=0 or p_evidence_hash !~ '^[0-9a-fA-F]{64}$' or(p_effective_to is not null and p_effective_to<=p_effective_from) then
    raise exception 'invalid residency lineage';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_business_id::text, 0));
  select lineage_hash into v_prev from public.gcc_data_residency_lineage where business_id=p_business_id order by created_at desc,lineage_id desc limit 1;
  v_hash:=encode(extensions.digest(convert_to(p_business_id::text||':'||p_country_code||':'||p_jurisdiction||':'||p_residency_class||':'||p_effective_from::text||':'||coalesce(p_effective_to::text,'')||':'||p_evidence_hash||':'||coalesce(v_prev,''),'UTF8'),'sha256'),'hex');
  insert into public.gcc_data_residency_lineage(business_id,country_code,jurisdiction,residency_class,effective_from,effective_to,evidence_hash,previous_hash,lineage_hash,created_by)
  values(p_business_id,p_country_code,p_jurisdiction,p_residency_class,p_effective_from,p_effective_to,p_evidence_hash,v_prev,v_hash,auth.uid()) returning lineage_id into v_id;
  return v_id;
end $$;

create or replace function public.gcc_post_tax_transaction(
  p_business_id uuid, p_tax_year integer, p_country_code text, p_tax_type text, p_invoice_number bigint,
  p_transaction_date date, p_currency_code text, p_taxable_amount numeric, p_tax_rate_bps integer,
  p_exchange_rate numeric, p_tax_status text, p_source_entity_type text, p_source_entity_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare v_id uuid; v_tax numeric; v_aed numeric; v_audit bigint;
begin
  if p_business_id is null or p_tax_year not between 2020 and 2100 or p_country_code not in('AE','SA','BH','KW','OM','QA') or p_tax_type not in('VAT','CORPORATE_TAX') or p_invoice_number is null or p_invoice_number<=0 or p_currency_code is null or p_taxable_amount<0 or p_tax_rate_bps not between 0 and 10000 or p_exchange_rate<=0 or p_tax_status not in('TAXABLE','ZERO_RATED','EXEMPT','OUT_OF_SCOPE') or length(btrim(p_source_entity_type))=0 then
    raise exception 'invalid fiscal transaction';
  end if;
  if p_tax_status in('ZERO_RATED','EXEMPT','OUT_OF_SCOPE') and p_tax_rate_bps<>0 then raise exception 'non-taxable status requires zero tax rate'; end if;
  select public.gcc_calculate_tax(p_taxable_amount,p_tax_rate_bps) into v_tax;
  v_aed:=round((p_taxable_amount+v_tax)*p_exchange_rate,4);
  insert into public.gcc_tax_ledger(business_id,tax_year,country_code,tax_type,invoice_number,transaction_date,currency_code,taxable_amount,tax_rate_bps,tax_amount,amount_aed,exchange_rate,tax_status,source_entity_type,source_entity_id,created_by)
  values(p_business_id,p_tax_year,p_country_code,p_tax_type,p_invoice_number,p_transaction_date,p_currency_code,p_taxable_amount,p_tax_rate_bps,v_tax,v_aed,p_exchange_rate,p_tax_status,p_source_entity_type,p_source_entity_id,auth.uid()) returning tax_entry_id into v_id;
  v_audit:=public.fta_append_audit_event(p_business_id,'TAX_TRANSACTION_POSTED','gcc_tax_ledger',v_id,p_invoice_number,jsonb_build_object('tax_year',p_tax_year,'country_code',p_country_code,'tax_type',p_tax_type,'currency_code',p_currency_code,'taxable_amount',p_taxable_amount,'tax_rate_bps',p_tax_rate_bps,'tax_amount',v_tax,'amount_aed',v_aed,'tax_status',p_tax_status,'source_entity_type',p_source_entity_type,'source_entity_id',p_source_entity_id));
  return v_id;
end $$;

create or replace function public.exchange_rates_append(
  p_base_currency text, p_quote_currency text, p_rate_date date, p_rate numeric,
  p_source text, p_source_reference text default null
) returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare v_id uuid;
begin
  if p_base_currency is null or p_quote_currency is null or p_base_currency=p_quote_currency or p_rate_date is null or p_rate<=0 or length(btrim(p_source))=0 then
    raise exception 'invalid exchange rate';
  end if;
  insert into public.exchange_rates(base_currency,quote_currency,rate_date,rate,source,source_reference,created_by)
  values(upper(btrim(p_base_currency)),upper(btrim(p_quote_currency)),p_rate_date,p_rate,btrim(p_source),nullif(btrim(p_source_reference),''),auth.uid())
  returning rate_id into v_id;
  return v_id;
end $$;

revoke insert on public.gcc_tax_ledger, public.fta_audit_log, public.gcc_data_residency_lineage, public.exchange_rates from service_role;
revoke update, delete on public.gcc_tax_ledger, public.fta_audit_log, public.gcc_data_residency_lineage, public.exchange_rates from service_role;
revoke all on function public.exchange_rates_append(text,text,date,numeric,text,text) from public, anon, authenticated;
grant execute on function public.exchange_rates_append(text,text,date,numeric,text,text) to service_role;
revoke all on function public.gcc_post_tax_transaction(uuid,integer,text,text,bigint,date,text,numeric,integer,numeric,text,text,uuid) from public, anon, authenticated;
grant execute on function public.gcc_post_tax_transaction(uuid,integer,text,text,bigint,date,text,numeric,integer,numeric,text,text,uuid) to service_role;
revoke all on function public.fta_append_audit_event(uuid,text,text,uuid,bigint,jsonb) from public, anon, authenticated;
grant execute on function public.fta_append_audit_event(uuid,text,text,uuid,bigint,jsonb) to service_role;
revoke all on function public.gcc_residency_append(uuid,text,text,text,timestamptz,timestamptz,text) from public, anon, authenticated;
grant execute on function public.gcc_residency_append(uuid,text,text,text,timestamptz,timestamptz,text) to service_role;

commit;