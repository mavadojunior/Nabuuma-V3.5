DO $$
DECLARE v_table text; v_rls boolean; v_has_select_policy boolean;
BEGIN
 FOREACH v_table IN ARRAY ARRAY['gcc_ledger_exchange_rates','v22_logistics_financial_valuations','v22_financial_forensic_ledger'] LOOP
  SELECT c.relrowsecurity INTO v_rls FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname=v_table AND c.relkind='r';
  IF NOT FOUND OR v_rls IS DISTINCT FROM true THEN RAISE EXCEPTION 'V3.6 self-check failed: RLS is not active on public.%',v_table; END IF;
 END LOOP;
 IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='calculate_gcc_localized_valuation' AND pg_catalog.pg_get_function_identity_arguments(p.oid)='p_shipment_id uuid, p_target_currency text' AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public']) THEN RAISE EXCEPTION 'V3.6 self-check failed: valuation SECURITY DEFINER/search_path invariant'; END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='append_financial_forensic_entry' AND pg_catalog.pg_get_function_identity_arguments(p.oid)='p_business_id uuid, p_source_document_id uuid, p_financial_payload jsonb' AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public']) THEN RAISE EXCEPTION 'V3.6 self-check failed: forensic SECURITY DEFINER/search_path invariant'; END IF;
 SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_policies WHERE schemaname='public' AND tablename='v22_logistics_financial_valuations' AND policyname='v36_financial_valuations_member_select' AND qual::text ILIKE '%is_member%') INTO v_has_select_policy;
 IF NOT v_has_select_policy THEN RAISE EXCEPTION 'V3.6 self-check failed: valuation tenant policy is missing or not bound to is_member'; END IF;
 SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_policies WHERE schemaname='public' AND tablename='v22_financial_forensic_ledger' AND policyname='v36_forensic_ledger_member_select' AND qual::text ILIKE '%is_member%') INTO v_has_select_policy;
 IF NOT v_has_select_policy THEN RAISE EXCEPTION 'V3.6 self-check failed: forensic tenant policy is missing or not bound to is_member'; END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conname='gcc_ledger_exchange_rates_unique_day') THEN RAISE EXCEPTION 'V3.6 self-check failed: FX composite unique constraint missing'; END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='v22_financial_forensic_ledger' AND t.tgname='trg_v22_forensic_ledger_append_only' AND NOT t.tgisinternal) THEN RAISE EXCEPTION 'V3.6 self-check failed: append-only trigger missing'; END IF;
 RAISE NOTICE 'V3.6 self-verification PASSED';
END; $$;