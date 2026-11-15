BEGIN;
DROP FUNCTION IF EXISTS public.v36_search_path_probe();

CREATE TABLE IF NOT EXISTS public.gcc_ledger_exchange_rates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), base_currency text NOT NULL, target_currency text NOT NULL, rate_date date NOT NULL,
  exchange_rate numeric(24,8) NOT NULL, source_name text NOT NULL DEFAULT 'official_benchmark', published_at timestamptz NOT NULL DEFAULT now(), created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT gcc_ledger_exchange_rates_base_chk CHECK (base_currency IN ('USD','EUR')),
  CONSTRAINT gcc_ledger_exchange_rates_target_chk CHECK (target_currency IN ('AED','SAR','BHD','KWD','OMR','QAR')),
  CONSTRAINT gcc_ledger_exchange_rates_positive_chk CHECK (exchange_rate > 0),
  CONSTRAINT gcc_ledger_exchange_rates_unique_day UNIQUE (base_currency,target_currency,rate_date)
);
CREATE INDEX IF NOT EXISTS idx_gcc_ledger_exchange_rates_lookup ON public.gcc_ledger_exchange_rates(base_currency,target_currency,rate_date DESC);

CREATE TABLE IF NOT EXISTS public.v22_logistics_financial_valuations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  shipment_id uuid NOT NULL REFERENCES public.v22_logistics_shipments(id) ON DELETE RESTRICT, source_currency text NOT NULL DEFAULT 'USD', target_currency text NOT NULL,
  rate_date date NOT NULL, exchange_rate numeric(24,8) NOT NULL, source_amount numeric(24,8) NOT NULL, localized_amount numeric(24,8) NOT NULL,
  customs_declared_value numeric(24,8) NOT NULL, vat_rate numeric(18,4) NOT NULL DEFAULT 0, vat_amount numeric(24,8) NOT NULL DEFAULT 0,
  corporate_tax_rate numeric(18,4) NOT NULL DEFAULT 0, corporate_tax_threshold numeric(24,8) NOT NULL DEFAULT 0, corporate_tax_provision numeric(24,8) NOT NULL DEFAULT 0,
  total_landed_cost numeric(24,8) NOT NULL, fiscal_status text NOT NULL DEFAULT 'calculated', calculation_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  calculated_at timestamptz NOT NULL DEFAULT now(), created_by uuid NOT NULL DEFAULT auth.uid(), created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT v22_logistics_financial_valuations_currency_chk CHECK (source_currency IN ('USD','EUR') AND target_currency IN ('AED','SAR','BHD','KWD','OMR','QAR')),
  CONSTRAINT v22_logistics_financial_valuations_positive_rate_chk CHECK (exchange_rate > 0),
  CONSTRAINT v22_logistics_financial_valuations_nonnegative_money_chk CHECK (source_amount>=0 AND localized_amount>=0 AND customs_declared_value>=0 AND vat_amount>=0 AND corporate_tax_threshold>=0 AND corporate_tax_provision>=0 AND total_landed_cost>=0),
  CONSTRAINT v22_logistics_financial_valuations_rate_chk CHECK (vat_rate>=0 AND corporate_tax_rate>=0),
  CONSTRAINT v22_logistics_financial_valuations_status_chk CHECK (fiscal_status IN ('calculated','finalized','superseded','void'))
);
CREATE INDEX IF NOT EXISTS idx_v22_logistics_financial_valuations_tenant ON public.v22_logistics_financial_valuations(business_id,calculated_at DESC);
CREATE INDEX IF NOT EXISTS idx_v22_logistics_financial_valuations_shipment ON public.v22_logistics_financial_valuations(shipment_id,calculated_at DESC);

CREATE TABLE IF NOT EXISTS public.v22_financial_forensic_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  sequence_no bigint NOT NULL, source_document_id uuid NOT NULL, financial_payload jsonb NOT NULL, previous_sha256 text,
  computed_sha256 text NOT NULL, created_by uuid NOT NULL DEFAULT auth.uid(), created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT v22_financial_forensic_ledger_sequence_chk CHECK (sequence_no>0),
  CONSTRAINT v22_financial_forensic_ledger_previous_hash_chk CHECK (previous_sha256 IS NULL OR previous_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT v22_financial_forensic_ledger_hash_chk CHECK (computed_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT v22_financial_forensic_ledger_sequence_uq UNIQUE (business_id,sequence_no),
  CONSTRAINT v22_financial_forensic_ledger_hash_uq UNIQUE (business_id,computed_sha256)
);
CREATE INDEX IF NOT EXISTS idx_v22_financial_forensic_ledger_business_sequence ON public.v22_financial_forensic_ledger(business_id,sequence_no DESC);

CREATE OR REPLACE FUNCTION public.v22_forensic_ledger_append_only_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$ BEGIN RAISE EXCEPTION 'v22_financial_forensic_ledger is append-only; UPDATE and DELETE are prohibited' USING ERRCODE='55006'; END; $$;
DROP TRIGGER IF EXISTS trg_v22_forensic_ledger_append_only ON public.v22_financial_forensic_ledger;
CREATE TRIGGER trg_v22_forensic_ledger_append_only BEFORE UPDATE OR DELETE ON public.v22_financial_forensic_ledger FOR EACH ROW EXECUTE FUNCTION public.v22_forensic_ledger_append_only_guard();

ALTER TABLE public.gcc_ledger_exchange_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.v22_logistics_financial_valuations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.v22_financial_forensic_ledger ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS v36_exchange_rates_authenticated_select ON public.gcc_ledger_exchange_rates;
CREATE POLICY v36_exchange_rates_authenticated_select ON public.gcc_ledger_exchange_rates FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS v36_financial_valuations_member_select ON public.v22_logistics_financial_valuations;
CREATE POLICY v36_financial_valuations_member_select ON public.v22_logistics_financial_valuations FOR SELECT TO authenticated USING ((SELECT public.is_member(business_id)));
DROP POLICY IF EXISTS v36_forensic_ledger_member_select ON public.v22_financial_forensic_ledger;
CREATE POLICY v36_forensic_ledger_member_select ON public.v22_financial_forensic_ledger FOR SELECT TO authenticated USING ((SELECT public.is_member(business_id)));

REVOKE ALL ON TABLE public.gcc_ledger_exchange_rates FROM PUBLIC,anon,authenticated;
REVOKE ALL ON TABLE public.v22_logistics_financial_valuations FROM PUBLIC,anon,authenticated;
REVOKE ALL ON TABLE public.v22_financial_forensic_ledger FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.gcc_ledger_exchange_rates TO authenticated;
GRANT SELECT ON TABLE public.v22_logistics_financial_valuations TO authenticated;
GRANT SELECT ON TABLE public.v22_financial_forensic_ledger TO authenticated;
GRANT ALL ON TABLE public.gcc_ledger_exchange_rates TO service_role;
GRANT ALL ON TABLE public.v22_logistics_financial_valuations TO service_role;
GRANT ALL ON TABLE public.v22_financial_forensic_ledger TO service_role;

CREATE OR REPLACE FUNCTION public.calculate_gcc_localized_valuation(p_shipment_id uuid,p_target_currency text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_shipment public.v22_logistics_shipments%ROWTYPE; v_rate public.gcc_ledger_exchange_rates%ROWTYPE; v_source_amount numeric(24,8); v_localized_amount numeric(24,8); v_vat_rate numeric(18,4):=0; v_vat_amount numeric(24,8):=0; v_ct_rate numeric(18,4):=0; v_ct_threshold numeric(24,8):=0; v_ct_provision numeric(24,8):=0; v_total numeric(24,8); v_id uuid;
BEGIN
 IF p_shipment_id IS NULL OR p_target_currency IS NULL THEN RAISE EXCEPTION 'shipment_id and target_currency are required' USING ERRCODE='22004'; END IF;
 p_target_currency:=upper(trim(p_target_currency));
 SELECT s.* INTO v_shipment FROM public.v22_logistics_shipments s WHERE s.id=p_shipment_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Shipment % does not exist',p_shipment_id USING ERRCODE='P0002'; END IF;
 IF NOT public.is_member(v_shipment.business_id) THEN RAISE EXCEPTION 'Caller is not a member of shipment business' USING ERRCODE='42501'; END IF;
 IF p_target_currency NOT IN ('AED','SAR','BHD','KWD','OMR','QAR') THEN RAISE EXCEPTION 'Unsupported GCC target currency: %',p_target_currency USING ERRCODE='22023'; END IF;
 IF v_shipment.purchase_order_id IS NULL THEN RAISE EXCEPTION 'Shipment % has no purchase order; source valuation cannot be derived safely',p_shipment_id USING ERRCODE='23502'; END IF;
 SELECT COALESCE(SUM(pol.ordered_quantity*COALESCE(pol.unit_price,pol.expected_unit_cost)),0)::numeric(24,8) INTO v_source_amount FROM public.purchase_order_lines pol WHERE pol.purchase_order_id=v_shipment.purchase_order_id AND pol.business_id=v_shipment.business_id;
 SELECT r.* INTO v_rate FROM public.gcc_ledger_exchange_rates r WHERE r.base_currency='USD' AND r.target_currency=p_target_currency AND r.rate_date<=CURRENT_DATE ORDER BY r.rate_date DESC LIMIT 1;
 IF NOT FOUND THEN RAISE EXCEPTION 'No USD/% FX benchmark exists on or before %',p_target_currency,CURRENT_DATE USING ERRCODE='P0002'; END IF;
 v_localized_amount:=round(v_source_amount*v_rate.exchange_rate,8); v_vat_rate:=CASE WHEN p_target_currency='AED' THEN 0.0500 ELSE 0.0000 END; v_vat_amount:=round(v_localized_amount*v_vat_rate,8);
 IF p_target_currency='AED' THEN v_ct_threshold:=375000.00000000; IF v_localized_amount>v_ct_threshold THEN v_ct_rate:=0.0900; v_ct_provision:=round((v_localized_amount-v_ct_threshold)*v_ct_rate,8); END IF; END IF;
 v_total:=v_localized_amount+v_vat_amount+v_ct_provision;
 INSERT INTO public.v22_logistics_financial_valuations(business_id,shipment_id,source_currency,target_currency,rate_date,exchange_rate,source_amount,localized_amount,customs_declared_value,vat_rate,vat_amount,corporate_tax_rate,corporate_tax_threshold,corporate_tax_provision,total_landed_cost,fiscal_status,calculation_metadata,calculated_at,created_by)
 VALUES(v_shipment.business_id,p_shipment_id,'USD',p_target_currency,v_rate.rate_date,v_rate.exchange_rate,v_source_amount,v_localized_amount,v_localized_amount,v_vat_rate,v_vat_amount,v_ct_rate,v_ct_threshold,v_ct_provision,v_total,'calculated',jsonb_build_object('valuation_basis','purchase_order_lines','fx_source',v_rate.source_name,'fx_rate_date',v_rate.rate_date,'uae_vat_standard_rate_applied',(p_target_currency='AED'),'corporate_tax_is_scenario_provision',(p_target_currency='AED'),'corporate_tax_legal_liability',false),now(),auth.uid()) RETURNING id INTO v_id; RETURN v_id;
END; $$;

CREATE OR REPLACE FUNCTION public.append_financial_forensic_entry(p_business_id uuid,p_source_document_id uuid,p_financial_payload jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_previous public.v22_financial_forensic_ledger%ROWTYPE; v_next_sequence bigint; v_previous_hash text; v_created_at timestamptz:=clock_timestamp(); v_hash_input text; v_hash text; v_id uuid;
BEGIN
 IF p_business_id IS NULL OR p_source_document_id IS NULL OR p_financial_payload IS NULL THEN RAISE EXCEPTION 'business_id, source_document_id and financial_payload are required' USING ERRCODE='22004'; END IF;
 IF NOT public.is_member(p_business_id) THEN RAISE EXCEPTION 'Caller is not a member of business %',p_business_id USING ERRCODE='42501'; END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_business_id::text,3601));
 SELECT l.* INTO v_previous FROM public.v22_financial_forensic_ledger l WHERE l.business_id=p_business_id ORDER BY l.sequence_no DESC LIMIT 1 FOR UPDATE;
 IF FOUND THEN v_next_sequence:=v_previous.sequence_no+1; v_previous_hash:=v_previous.computed_sha256; ELSE v_next_sequence:=1; v_previous_hash:=NULL; END IF;
 v_hash_input:=concat_ws('|',p_business_id::text,v_next_sequence::text,coalesce(v_previous_hash,''),p_source_document_id::text,p_financial_payload::text,to_char(v_created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
 v_hash:=encode(digest(v_hash_input,'sha256'),'hex');
 INSERT INTO public.v22_financial_forensic_ledger(business_id,sequence_no,source_document_id,financial_payload,previous_sha256,computed_sha256,created_by,created_at) VALUES(p_business_id,v_next_sequence,p_source_document_id,p_financial_payload,v_previous_hash,v_hash,auth.uid(),v_created_at) RETURNING id INTO v_id;
 RETURN v_id;
END; $$;

REVOKE ALL ON FUNCTION public.calculate_gcc_localized_valuation(uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.append_financial_forensic_entry(uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_gcc_localized_valuation(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.append_financial_forensic_entry(uuid,uuid,jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.v22_forensic_ledger_append_only_guard() FROM PUBLIC,anon,authenticated;
COMMIT;