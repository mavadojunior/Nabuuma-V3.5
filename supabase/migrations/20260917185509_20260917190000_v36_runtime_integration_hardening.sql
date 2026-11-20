-- V3.6 runtime integration hardening: make the live data plane executable without inventing business records.
-- Global FX reference data is seeded only for the six supported GCC target currencies.
-- Rates are explicit placeholders? No: this migration intentionally does NOT invent financial benchmarks.
-- Instead, it adds operational guardrails and indexes required for runtime execution.

CREATE INDEX IF NOT EXISTS idx_gcc_ledger_exchange_rates_rate_date
  ON public.gcc_ledger_exchange_rates(rate_date DESC);

CREATE INDEX IF NOT EXISTS idx_v22_financial_forensic_ledger_source_document
  ON public.v22_financial_forensic_ledger(business_id, source_document_id, sequence_no DESC);

CREATE INDEX IF NOT EXISTS idx_v22_logistics_financial_valuations_fiscal_status
  ON public.v22_logistics_financial_valuations(business_id, fiscal_status, calculated_at DESC);

-- Ensure the append-only guard remains enabled after any future schema refresh.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.v22_financial_forensic_ledger'::regclass
      AND tgname='trg_v22_forensic_ledger_append_only'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'V3.6 integrity guard missing: forensic append-only trigger is not installed';
  END IF;
END $$;

-- Verify the controlled RPCs remain callable by authenticated clients and not anonymously.
DO $$
DECLARE
  v_oid oid;
BEGIN
  SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='calculate_gcc_localized_valuation'
    AND pg_get_function_identity_arguments(p.oid)='p_shipment_id uuid, p_target_currency text';
  IF v_oid IS NULL OR NOT has_function_privilege('authenticated',v_oid,'EXECUTE') OR has_function_privilege('anon',v_oid,'EXECUTE') THEN
    RAISE EXCEPTION 'V3.6 valuation RPC privilege contract failed';
  END IF;

  SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='append_financial_forensic_entry'
    AND pg_get_function_identity_arguments(p.oid)='p_business_id uuid, p_source_document_id uuid, p_financial_payload jsonb';
  IF v_oid IS NULL OR NOT has_function_privilege('authenticated',v_oid,'EXECUTE') OR has_function_privilege('anon',v_oid,'EXECUTE') THEN
    RAISE EXCEPTION 'V3.6 forensic RPC privilege contract failed';
  END IF;
END $$;

-- Verify the tenant-owned V3.6 tables cannot be directly mutated by authenticated clients.
DO $$
BEGIN
  IF has_table_privilege('authenticated','public.v22_logistics_financial_valuations','INSERT')
     OR has_table_privilege('authenticated','public.v22_logistics_financial_valuations','UPDATE')
     OR has_table_privilege('authenticated','public.v22_logistics_financial_valuations','DELETE')
     OR has_table_privilege('authenticated','public.v22_financial_forensic_ledger','INSERT')
     OR has_table_privilege('authenticated','public.v22_financial_forensic_ledger','UPDATE')
     OR has_table_privilege('authenticated','public.v22_financial_forensic_ledger','DELETE') THEN
    RAISE EXCEPTION 'V3.6 direct authenticated mutation privilege contract failed';
  END IF;
END $$;