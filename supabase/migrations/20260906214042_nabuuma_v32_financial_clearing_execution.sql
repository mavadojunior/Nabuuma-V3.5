-- Nabuuma V3.2 Financial Clearing Plane
-- Production-safe foundation built against the live V3.1 schema.
-- Deliberately excludes automatic RLS remediation of legacy objects identified by the security advisor.

CREATE TABLE public.financial_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  account_code text NOT NULL,
  account_name text NOT NULL,
  account_type text NOT NULL CHECK (account_type IN ('Asset','Liability','Equity','Revenue','Expense')),
  currency text NOT NULL CHECK (length(currency) = 3),
  balance_minor bigint NOT NULL DEFAULT 0,
  available_minor bigint NOT NULL DEFAULT 0,
  escrow_minor bigint NOT NULL DEFAULT 0,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (business_id, account_code, currency)
);

CREATE TABLE public.financial_ledger_entries (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_id uuid NOT NULL,
  business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  account_id uuid NOT NULL REFERENCES public.financial_accounts(id) ON DELETE RESTRICT,
  currency text NOT NULL CHECK (length(currency) = 3),
  debit_minor bigint NOT NULL DEFAULT 0 CHECK (debit_minor >= 0),
  credit_minor bigint NOT NULL DEFAULT 0 CHECK (credit_minor >= 0),
  source_type text NOT NULL,
  source_id uuid,
  previous_entry_hash text,
  entry_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT financial_ledger_entries_one_side_chk CHECK ((debit_minor > 0)::integer + (credit_minor > 0)::integer = 1),
  CONSTRAINT financial_ledger_entries_hash_len_chk CHECK (length(entry_hash) = 64),
  UNIQUE (transaction_id, id)
);

CREATE INDEX financial_accounts_business_idx ON public.financial_accounts(business_id, account_code, currency);
CREATE INDEX financial_ledger_entries_transaction_idx ON public.financial_ledger_entries(transaction_id, id);
CREATE INDEX financial_ledger_entries_business_idx ON public.financial_ledger_entries(business_id, created_at);
CREATE INDEX financial_ledger_entries_source_idx ON public.financial_ledger_entries(source_type, source_id);

CREATE TABLE public.network_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_number text NOT NULL UNIQUE,
  buyer_business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  seller_business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  currency text NOT NULL CHECK (length(currency) = 3),
  status text NOT NULL DEFAULT 'compiled' CHECK (status IN ('compiled','settled','voided')),
  subtotal_minor bigint NOT NULL DEFAULT 0 CHECK (subtotal_minor >= 0),
  tax_minor bigint NOT NULL DEFAULT 0 CHECK (tax_minor >= 0),
  total_minor bigint NOT NULL DEFAULT 0 CHECK (total_minor >= 0),
  immutable_block_hash text,
  compiled_at timestamptz NOT NULL DEFAULT now(),
  settled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.network_invoice_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid NOT NULL REFERENCES public.network_invoices(id) ON DELETE RESTRICT,
  purchase_order_line_id uuid NOT NULL REFERENCES public.purchase_order_lines(id) ON DELETE RESTRICT,
  dispatch_line_id uuid NOT NULL REFERENCES public.network_order_dispatch_lines(id) ON DELETE RESTRICT,
  delivery_proof_id uuid NOT NULL REFERENCES public.network_dispatched_receipts(id) ON DELETE RESTRICT,
  ingredient_id uuid REFERENCES public.ingredients(id) ON DELETE RESTRICT,
  quantity numeric(24,8) NOT NULL CHECK (quantity > 0),
  unit text NOT NULL,
  unit_price_minor bigint NOT NULL CHECK (unit_price_minor >= 0),
  subtotal_minor bigint NOT NULL CHECK (subtotal_minor >= 0),
  tax_rate_bps integer NOT NULL DEFAULT 0 CHECK (tax_rate_bps BETWEEN 0 AND 10000),
  tax_minor bigint NOT NULL DEFAULT 0 CHECK (tax_minor >= 0),
  total_minor bigint NOT NULL CHECK (total_minor >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (purchase_order_line_id, dispatch_line_id, delivery_proof_id)
);

CREATE INDEX network_invoices_buyer_idx ON public.network_invoices(buyer_business_id, created_at);
CREATE INDEX network_invoices_seller_idx ON public.network_invoices(seller_business_id, created_at);
CREATE INDEX network_invoice_lines_invoice_idx ON public.network_invoice_lines(invoice_id);
CREATE INDEX network_invoice_lines_po_idx ON public.network_invoice_lines(purchase_order_line_id);
CREATE INDEX network_invoice_lines_dispatch_idx ON public.network_invoice_lines(dispatch_line_id);
CREATE INDEX network_invoice_lines_receipt_idx ON public.network_invoice_lines(delivery_proof_id);

CREATE TABLE public.settlement_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_number text NOT NULL UNIQUE,
  buyer_business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  seller_business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  currency text NOT NULL CHECK (length(currency) = 3),
  state text NOT NULL DEFAULT 'compiled' CHECK (state IN ('compiled','escrow_locked','processing','settled','reconciled','failed')),
  total_minor bigint NOT NULL DEFAULT 0 CHECK (total_minor >= 0),
  compiled_at timestamptz NOT NULL DEFAULT now(),
  escrow_locked_at timestamptz,
  processing_at timestamptz,
  settled_at timestamptz,
  reconciled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.settlement_batch_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  settlement_batch_id uuid NOT NULL REFERENCES public.settlement_batches(id) ON DELETE RESTRICT,
  invoice_id uuid NOT NULL UNIQUE REFERENCES public.network_invoices(id) ON DELETE RESTRICT,
  amount_minor bigint NOT NULL CHECK (amount_minor > 0),
  currency text NOT NULL CHECK (length(currency) = 3),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.multi_tenant_escrow_controls (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  settlement_batch_id uuid NOT NULL UNIQUE REFERENCES public.settlement_batches(id) ON DELETE RESTRICT,
  buyer_business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  seller_business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  currency text NOT NULL CHECK (length(currency) = 3),
  amount_minor bigint NOT NULL CHECK (amount_minor > 0),
  state text NOT NULL DEFAULT 'compiled' CHECK (state IN ('compiled','escrow_locked','processing','settled','reconciled')),
  state_hash text,
  compiled_at timestamptz NOT NULL DEFAULT now(),
  escrow_locked_at timestamptz,
  processing_at timestamptz,
  settled_at timestamptz,
  reconciled_at timestamptz
);

CREATE TABLE public.network_dispatch_financial_clearances (
  dispatch_id uuid PRIMARY KEY REFERENCES public.network_order_dispatches(id) ON DELETE RESTRICT,
  buyer_business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  seller_business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  state text NOT NULL DEFAULT 'uncleared' CHECK (state IN ('uncleared','cleared')),
  settlement_batch_id uuid REFERENCES public.settlement_batches(id) ON DELETE RESTRICT,
  cleared_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX settlement_batches_pair_idx ON public.settlement_batches(buyer_business_id, seller_business_id, currency, state);
CREATE INDEX settlement_batch_lines_batch_idx ON public.settlement_batch_lines(settlement_batch_id);
CREATE INDEX escrow_controls_pair_idx ON public.multi_tenant_escrow_controls(buyer_business_id, seller_business_id, currency, state);
CREATE INDEX dispatch_financial_clearance_batch_idx ON public.network_dispatch_financial_clearances(settlement_batch_id);

CREATE OR REPLACE FUNCTION public.v32_is_trusted_executor()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
  SELECT current_user = 'postgres' OR coalesce(auth.role(),'') = 'service_role';
$$;

CREATE OR REPLACE FUNCTION public.v32_tenant_pair_lock(p_buyer uuid, p_seller uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE v_key bigint;
BEGIN
  IF p_buyer IS NULL OR p_seller IS NULL OR p_buyer = p_seller THEN
    RAISE EXCEPTION 'invalid tenant pair';
  END IF;
  v_key := hashtextextended(least(p_buyer::text,p_seller::text) || ':' || greatest(p_buyer::text,p_seller::text), 3202);
  PERFORM pg_advisory_xact_lock(v_key);
END;
$$;

CREATE OR REPLACE FUNCTION public.v32_financial_account_id(p_business_id uuid, p_code text, p_currency text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN RAISE EXCEPTION 'trusted executor required'; END IF;
  SELECT id INTO v_id FROM public.financial_accounts WHERE business_id=p_business_id AND account_code=p_code AND currency=p_currency FOR UPDATE;
  IF v_id IS NULL THEN
    INSERT INTO public.financial_accounts(business_id,account_code,account_name,account_type,currency)
    VALUES
      (p_business_id,'CASH','Cash','Asset',p_currency),
      (p_business_id,'ESCROW_ASSET','Settlement Escrow','Asset',p_currency),
      (p_business_id,'AP','Accounts Payable','Liability',p_currency),
      (p_business_id,'AR','Accounts Receivable','Asset',p_currency),
      (p_business_id,'REVENUE','Network Revenue','Revenue',p_currency),
      (p_business_id,'EXPENSE','Network Expense','Expense',p_currency)
    ON CONFLICT (business_id,account_code,currency) DO NOTHING;
    SELECT id INTO v_id FROM public.financial_accounts WHERE business_id=p_business_id AND account_code=p_code AND currency=p_currency FOR UPDATE;
  END IF;
  IF v_id IS NULL THEN RAISE EXCEPTION 'financial account creation failed'; END IF;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.v32_ledger_hash(p_previous text, p_transaction_id uuid, p_business_id uuid, p_account_id uuid, p_currency text, p_debit bigint, p_credit bigint, p_source_type text, p_source_id uuid)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, extensions, pg_temp
AS $$
  SELECT encode(extensions.digest(coalesce(p_previous,'') || '|' || jsonb_build_object('transaction_id',p_transaction_id,'business_id',p_business_id,'account_id',p_account_id,'currency',p_currency,'debit_minor',p_debit,'credit_minor',p_credit,'source_type',p_source_type,'source_id',p_source_id)::text,'sha256'),'hex');
$$;

CREATE OR REPLACE FUNCTION public.v32_ledger_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE v_prev text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('nabuuma:v32:ledger-chain',3202));
  SELECT entry_hash INTO v_prev FROM public.financial_ledger_entries ORDER BY id DESC LIMIT 1;
  NEW.previous_entry_hash := v_prev;
  NEW.entry_hash := public.v32_ledger_hash(v_prev,NEW.transaction_id,NEW.business_id,NEW.account_id,NEW.currency,NEW.debit_minor,NEW.credit_minor,NEW.source_type,NEW.source_id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER financial_ledger_entries_hash_bi
BEFORE INSERT ON public.financial_ledger_entries
FOR EACH ROW EXECUTE FUNCTION public.v32_ledger_before_insert();

CREATE OR REPLACE FUNCTION public.v32_ledger_after_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
BEGIN
  UPDATE public.financial_accounts
  SET balance_minor = balance_minor + NEW.debit_minor - NEW.credit_minor,
      available_minor = CASE WHEN account_code='CASH' THEN available_minor + NEW.debit_minor - NEW.credit_minor ELSE available_minor END,
      escrow_minor = CASE WHEN account_code='ESCROW_ASSET' THEN escrow_minor + NEW.debit_minor - NEW.credit_minor ELSE escrow_minor END
  WHERE id = NEW.account_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ledger account missing: %',NEW.account_id; END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER financial_ledger_entries_balance_ai
AFTER INSERT ON public.financial_ledger_entries
FOR EACH ROW EXECUTE FUNCTION public.v32_ledger_after_insert();

CREATE OR REPLACE FUNCTION public.v32_assert_ledger_transaction_balanced()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE v_debit bigint; v_credit bigint; v_count integer;
BEGIN
  SELECT count(*),coalesce(sum(debit_minor),0),coalesce(sum(credit_minor),0) INTO v_count,v_debit,v_credit FROM public.financial_ledger_entries WHERE transaction_id=NEW.transaction_id;
  IF v_count < 2 OR v_debit <> v_credit THEN
    RAISE EXCEPTION 'financial transaction % is not balanced: debit %, credit %, entries %',NEW.transaction_id,v_debit,v_credit,v_count;
  END IF;
  RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER financial_ledger_transaction_balance_ct
AFTER INSERT ON public.financial_ledger_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION public.v32_assert_ledger_transaction_balanced();

CREATE OR REPLACE FUNCTION public.v32_immutable_ledger_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'financial ledger is append-only';
END;
$$;
CREATE TRIGGER financial_ledger_no_update BEFORE UPDATE OR DELETE ON public.financial_ledger_entries FOR EACH ROW EXECUTE FUNCTION public.v32_immutable_ledger_guard();

CREATE OR REPLACE FUNCTION public.v32_append_ledger_transaction(p_transaction_id uuid, p_entries jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE r jsonb; v_debit bigint; v_credit bigint; v_business uuid; v_account uuid; v_currency text; v_sum_d bigint:=0; v_sum_c bigint:=0; v_count integer:=0;
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN RAISE EXCEPTION 'trusted executor required'; END IF;
  IF p_transaction_id IS NULL OR jsonb_typeof(p_entries) <> 'array' OR jsonb_array_length(p_entries) < 2 THEN RAISE EXCEPTION 'invalid ledger transaction payload'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('nabuuma:v32:ledger-chain',3202));
  FOR r IN SELECT value FROM jsonb_array_elements(p_entries) LOOP
    v_debit := coalesce((r->>'debit_minor')::bigint,0);
    v_credit := coalesce((r->>'credit_minor')::bigint,0);
    v_business := (r->>'business_id')::uuid;
    v_account := (r->>'account_id')::uuid;
    v_currency := r->>'currency';
    IF v_business IS NULL OR v_account IS NULL OR v_currency IS NULL OR length(v_currency) <> 3 THEN RAISE EXCEPTION 'invalid ledger entry'; END IF;
    IF (v_debit > 0)::integer + (v_credit > 0)::integer <> 1 THEN RAISE EXCEPTION 'ledger entry must contain exactly one positive side'; END IF;
    IF v_debit < 0 OR v_credit < 0 THEN RAISE EXCEPTION 'negative ledger amount'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.financial_accounts a WHERE a.id=v_account AND a.business_id=v_business AND a.currency=v_currency AND a.active) THEN RAISE EXCEPTION 'ledger account does not belong to business/currency'; END IF;
    v_sum_d:=v_sum_d+v_debit; v_sum_c:=v_sum_c+v_credit; v_count:=v_count+1;
    INSERT INTO public.financial_ledger_entries(transaction_id,business_id,account_id,currency,debit_minor,credit_minor,source_type,source_id)
    VALUES(p_transaction_id,v_business,v_account,v_currency,v_debit,v_credit,r->>'source_type',nullif(r->>'source_id','')::uuid);
  END LOOP;
  IF v_count < 2 OR v_sum_d <> v_sum_c THEN RAISE EXCEPTION 'unbalanced ledger transaction'; END IF;
  RETURN p_transaction_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.v32_invoice_hash(p_invoice uuid)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public, extensions, pg_temp
AS $$
  SELECT encode(extensions.digest(jsonb_build_object('invoice',to_jsonb(i),'lines',coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM public.network_invoice_lines l WHERE l.invoice_id=i.id),'[]'::jsonb))::text,'sha256'),'hex') FROM public.network_invoices i WHERE i.id=p_invoice;
$$;

CREATE OR REPLACE FUNCTION public.v32_invoice_immutable_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
BEGIN
  IF coalesce(current_setting('nabuuma.v32_building_invoice',true),'0') <> '1' THEN RAISE EXCEPTION 'invoice is immutable; use adjustment documents'; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER network_invoices_immutable_guard BEFORE UPDATE OR DELETE ON public.network_invoices FOR EACH ROW EXECUTE FUNCTION public.v32_invoice_immutable_guard();
CREATE TRIGGER network_invoice_lines_immutable_guard BEFORE UPDATE OR DELETE ON public.network_invoice_lines FOR EACH ROW EXECUTE FUNCTION public.v32_invoice_immutable_guard();

CREATE OR REPLACE FUNCTION public.v32_escrow_transition_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
BEGIN
  IF NEW.state IS DISTINCT FROM OLD.state AND NOT ((OLD.state='compiled' AND NEW.state='escrow_locked') OR (OLD.state='escrow_locked' AND NEW.state='processing') OR (OLD.state='processing' AND NEW.state='settled') OR (OLD.state='settled' AND NEW.state='reconciled')) THEN
    RAISE EXCEPTION 'invalid escrow state transition % -> %',OLD.state,NEW.state;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER multi_tenant_escrow_state_guard BEFORE UPDATE OF state ON public.multi_tenant_escrow_controls FOR EACH ROW EXECUTE FUNCTION public.v32_escrow_transition_guard();

CREATE OR REPLACE FUNCTION public.v32_assert_settlement_line_clear(p_invoice_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN RAISE EXCEPTION 'trusted executor required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.network_invoices i WHERE i.id=p_invoice_id AND i.status='compiled') THEN RAISE EXCEPTION 'invoice is not financially clearable'; END IF;
  IF EXISTS (SELECT 1 FROM public.network_invoice_lines l JOIN public.network_dispatches_disputes d ON d.dispatch_id=(SELECT dl.dispatch_id FROM public.network_order_dispatch_lines dl WHERE dl.id=l.dispatch_line_id) WHERE l.invoice_id=p_invoice_id AND d.status IN ('open','under_review')) THEN RAISE EXCEPTION 'invoice has unresolved dispatch dispute'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.v32_three_way_match(p_po_line_id uuid,p_dispatch_line_id uuid,p_delivery_proof_id uuid,p_tax_rate_bps integer DEFAULT 0)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE po record; dl record; d record; rc record; so record; v_existing uuid; v_clear numeric; v_already_po numeric; v_already_receipt numeric; v_sub_numeric numeric; v_tax_numeric numeric; v_sub bigint; v_tax bigint; v_total bigint; v_invoice uuid; v_invoice_no text; v_currency text;
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN RAISE EXCEPTION 'trusted executor required'; END IF;
  IF p_tax_rate_bps IS NULL OR p_tax_rate_bps < 0 OR p_tax_rate_bps > 10000 THEN RAISE EXCEPTION 'invalid tax rate'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('nabuuma:v32:match:'||coalesce(p_po_line_id::text,'')||':'||coalesce(p_dispatch_line_id::text,'')||':'||coalesce(p_delivery_proof_id::text,''),3202));
  SELECT * INTO po FROM public.purchase_order_lines WHERE id=p_po_line_id FOR UPDATE;
  SELECT dl.*, d.sales_order_id, d.status AS dispatch_status, d.buyer_business_id AS dispatch_buyer, d.seller_business_id AS dispatch_seller INTO dl FROM public.network_order_dispatch_lines dl JOIN public.network_order_dispatches d ON d.id=dl.dispatch_id WHERE dl.id=p_dispatch_line_id FOR UPDATE;
  SELECT * INTO rc FROM public.network_dispatched_receipts WHERE id=p_delivery_proof_id FOR UPDATE;
  IF po.id IS NULL OR dl.id IS NULL OR rc.id IS NULL THEN RAISE EXCEPTION 'three-way evidence row missing'; END IF;
  SELECT * INTO so FROM public.network_sales_order_lines WHERE id=dl.sales_order_line_id FOR UPDATE;
  SELECT * INTO d FROM public.network_order_dispatches WHERE id=dl.dispatch_id FOR UPDATE;
  IF so.id IS NULL OR d.id IS NULL THEN RAISE EXCEPTION 'sales order/dispatch relationship missing'; END IF;
  IF dl.dispatch_id <> rc.dispatch_id THEN RAISE EXCEPTION 'delivery proof does not belong to dispatch'; END IF;
  IF dl.buyer_business_id <> d.buyer_business_id OR dl.seller_business_id <> d.seller_business_id OR so.buyer_business_id <> d.buyer_business_id OR so.seller_business_id <> d.seller_business_id OR rc.buyer_business_id <> d.buyer_business_id OR rc.seller_business_id <> d.seller_business_id THEN RAISE EXCEPTION 'tenant party mismatch'; END IF;
  IF so.ingredient_id IS DISTINCT FROM po.ingredient_id THEN RAISE EXCEPTION 'ingredient mismatch between PO and network order'; END IF;
  IF lower(trim(po.unit)) <> lower(trim(dl.unit)) OR lower(trim(dl.unit)) <> lower(trim(rc.unit)) OR lower(trim(rc.unit)) <> lower(trim(so.unit)) THEN RAISE EXCEPTION 'exact unit mismatch'; END IF;
  IF d.status <> 'delivered' THEN RAISE EXCEPTION 'dispatch must be delivered before invoice compilation'; END IF;
  IF rc.receipt_status <> 'committed' THEN RAISE EXCEPTION 'delivery proof is not committed'; END IF;
  IF EXISTS (SELECT 1 FROM public.network_dispatches_disputes x WHERE x.dispatch_id=d.id AND x.status IN ('open','under_review')) THEN RAISE EXCEPTION 'dispatch has unresolved dispute'; END IF;
  SELECT coalesce(sum(l.quantity),0) INTO v_already_po FROM public.network_invoice_lines l WHERE l.purchase_order_line_id=po.id;
  SELECT coalesce(sum(l.quantity),0) INTO v_already_receipt FROM public.network_invoice_lines l WHERE l.delivery_proof_id=rc.id;
  v_clear := least(po.ordered_quantity - greatest(po.received_quantity, v_already_po), dl.quantity, rc.received_quantity - v_already_receipt);
  IF v_clear <= 0 THEN RAISE EXCEPTION 'no clear quantity remains'; END IF;
  IF v_clear > so.quantity THEN v_clear := so.quantity; END IF;
  v_sub_numeric := v_clear * so.unit_price_minor::numeric;
  IF v_sub_numeric <> trunc(v_sub_numeric) THEN RAISE EXCEPTION 'fractional minor-unit subtotal is not permitted'; END IF;
  v_sub := v_sub_numeric::bigint;
  v_tax_numeric := round(v_sub_numeric * p_tax_rate_bps::numeric / 10000,0);
  IF v_tax_numeric <> trunc(v_tax_numeric) THEN RAISE EXCEPTION 'tax rounding did not produce an integer minor unit'; END IF;
  v_tax := v_tax_numeric::bigint; v_total := v_sub + v_tax; v_currency := (SELECT currency FROM public.network_sales_orders WHERE id=so.sales_order_id);
  IF v_currency IS NULL OR length(v_currency) <> 3 THEN RAISE EXCEPTION 'invalid sales-order currency'; END IF;
  SELECT i.id INTO v_existing FROM public.network_invoices i JOIN public.network_invoice_lines l ON l.invoice_id=i.id WHERE l.purchase_order_line_id=po.id AND l.dispatch_line_id=dl.id AND l.delivery_proof_id=rc.id LIMIT 1;
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
  v_invoice := gen_random_uuid();
  v_invoice_no := 'NAB-V32-'||upper(replace(v_invoice::text,'-',''));
  PERFORM set_config('nabuuma.v32_building_invoice','1',true);
  INSERT INTO public.network_invoices(id,invoice_number,buyer_business_id,seller_business_id,currency,subtotal_minor,tax_minor,total_minor) VALUES(v_invoice,v_invoice_no,d.buyer_business_id,d.seller_business_id,v_currency,v_sub,v_tax,v_total);
  INSERT INTO public.network_invoice_lines(invoice_id,purchase_order_line_id,dispatch_line_id,delivery_proof_id,ingredient_id,quantity,unit,unit_price_minor,subtotal_minor,tax_rate_bps,tax_minor,total_minor) VALUES(v_invoice,po.id,dl.id,rc.id,po.ingredient_id,v_clear,po.unit,so.unit_price_minor,v_sub,p_tax_rate_bps,v_tax,v_total);
  UPDATE public.network_invoices SET immutable_block_hash=public.v32_invoice_hash(v_invoice) WHERE id=v_invoice;
  PERFORM set_config('nabuuma.v32_building_invoice','0',true);
  RETURN v_invoice;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('nabuuma.v32_building_invoice','0',true);
  RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION public.v32_compile_settlement_batch(p_invoice_ids uuid[])
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE v_batch uuid:=gen_random_uuid(); v_buyer uuid; v_seller uuid; v_currency text; v_total bigint; v_invoice uuid; v_number text;
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN RAISE EXCEPTION 'trusted executor required'; END IF;
  IF p_invoice_ids IS NULL OR cardinality(p_invoice_ids)=0 THEN RAISE EXCEPTION 'invoice list is empty'; END IF;
  SELECT buyer_business_id,seller_business_id,currency INTO v_buyer,v_seller,v_currency FROM public.network_invoices WHERE id=p_invoice_ids[1] FOR UPDATE;
  IF v_buyer IS NULL THEN RAISE EXCEPTION 'first invoice missing'; END IF;
  PERFORM public.v32_tenant_pair_lock(v_buyer,v_seller);
  IF EXISTS (SELECT 1 FROM public.network_invoices i WHERE i.id=ANY(p_invoice_ids) AND (i.status <> 'compiled' OR i.buyer_business_id<>v_buyer OR i.seller_business_id<>v_seller OR i.currency<>v_currency)) THEN RAISE EXCEPTION 'invoice set is not homogeneous and clearable'; END IF;
  SELECT coalesce(sum(i.total_minor),0) INTO v_total FROM public.network_invoices i WHERE i.id=ANY(p_invoice_ids);
  IF v_total <= 0 THEN RAISE EXCEPTION 'settlement total must be positive'; END IF;
  v_number := 'SET-V32-'||upper(replace(v_batch::text,'-',''));
  INSERT INTO public.settlement_batches(id,batch_number,buyer_business_id,seller_business_id,currency,total_minor) VALUES(v_batch,v_number,v_buyer,v_seller,v_currency,v_total);
  FOREACH v_invoice IN ARRAY p_invoice_ids LOOP
    PERFORM public.v32_assert_settlement_line_clear(v_invoice);
    INSERT INTO public.settlement_batch_lines(settlement_batch_id,invoice_id,amount_minor,currency) SELECT v_batch,id,total_minor,currency FROM public.network_invoices WHERE id=v_invoice;
  END LOOP;
  INSERT INTO public.multi_tenant_escrow_controls(settlement_batch_id,buyer_business_id,seller_business_id,currency,amount_minor,state_hash) VALUES(v_batch,v_buyer,v_seller,v_currency,v_total,encode(extensions.digest(v_batch::text||'|'||v_total::text,'sha256'),'hex'));
  RETURN v_batch;
END;
$$;

CREATE OR REPLACE FUNCTION public.clear_v32_settlement_batch(p_batch_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE b record; e record; i record; v_cash uuid; v_escrow uuid; v_ap uuid; v_expense uuid; v_ar uuid; v_revenue uuid; v_tx uuid; v_posted boolean; v_total bigint:=0; v_dispatch uuid;
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN RAISE EXCEPTION 'trusted executor required'; END IF;
  SELECT * INTO b FROM public.settlement_batches WHERE id=p_batch_id FOR UPDATE;
  IF b.id IS NULL THEN RAISE EXCEPTION 'settlement batch not found'; END IF;
  PERFORM public.v32_tenant_pair_lock(b.buyer_business_id,b.seller_business_id);
  SELECT * INTO e FROM public.multi_tenant_escrow_controls WHERE settlement_batch_id=p_batch_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'escrow control not found'; END IF;
  IF b.state='reconciled' THEN RETURN p_batch_id; END IF;
  IF b.state <> 'compiled' THEN RAISE EXCEPTION 'batch must be compiled before clearing'; END IF;
  IF e.state <> 'compiled' THEN RAISE EXCEPTION 'escrow must be compiled'; END IF;
  SELECT balance_minor INTO v_total FROM public.financial_accounts WHERE business_id=b.buyer_business_id AND account_code='CASH' AND currency=b.currency FOR UPDATE;
  IF coalesce(v_total,0) < b.total_minor THEN RAISE EXCEPTION 'insufficient buyer cash'; END IF;
  PERFORM public.v32_financial_account_id(b.buyer_business_id,'CASH',b.currency);
  PERFORM public.v32_financial_account_id(b.buyer_business_id,'ESCROW_ASSET',b.currency);
  PERFORM public.v32_financial_account_id(b.buyer_business_id,'AP',b.currency);
  PERFORM public.v32_financial_account_id(b.buyer_business_id,'EXPENSE',b.currency);
  PERFORM public.v32_financial_account_id(b.seller_business_id,'CASH',b.currency);
  PERFORM public.v32_financial_account_id(b.seller_business_id,'AR',b.currency);
  PERFORM public.v32_financial_account_id(b.seller_business_id,'REVENUE',b.currency);
  SELECT id INTO v_cash FROM public.financial_accounts WHERE business_id=b.buyer_business_id AND account_code='CASH' AND currency=b.currency;
  SELECT id INTO v_escrow FROM public.financial_accounts WHERE business_id=b.buyer_business_id AND account_code='ESCROW_ASSET' AND currency=b.currency;
  SELECT id INTO v_ap FROM public.financial_accounts WHERE business_id=b.buyer_business_id AND account_code='AP' AND currency=b.currency;
  SELECT id INTO v_expense FROM public.financial_accounts WHERE business_id=b.buyer_business_id AND account_code='EXPENSE' AND currency=b.currency;
  -- Recognition: buyer Dr Expense / Cr AP; seller Dr AR / Cr Revenue.
  FOR i IN SELECT * FROM public.settlement_batch_lines WHERE settlement_batch_id=p_batch_id ORDER BY id FOR UPDATE LOOP
    SELECT n.* INTO e FROM public.network_invoices n WHERE n.id=i.invoice_id FOR UPDATE;
    IF e.status <> 'compiled' THEN RAISE EXCEPTION 'invoice % is not compiled',e.id; END IF;
    v_tx:=gen_random_uuid();
    PERFORM public.v32_append_ledger_transaction(v_tx,jsonb_build_array(
      jsonb_build_object('business_id',e.buyer_business_id,'account_id',v_expense,'currency',e.currency,'debit_minor',e.total_minor,'credit_minor',0,'source_type','network_invoice','source_id',e.id),
      jsonb_build_object('business_id',e.buyer_business_id,'account_id',v_ap,'currency',e.currency,'debit_minor',0,'credit_minor',e.total_minor,'source_type','network_invoice','source_id',e.id)));
    SELECT id INTO v_ar FROM public.financial_accounts WHERE business_id=e.seller_business_id AND account_code='AR' AND currency=e.currency;
    SELECT id INTO v_revenue FROM public.financial_accounts WHERE business_id=e.seller_business_id AND account_code='REVENUE' AND currency=e.currency;
    v_tx:=gen_random_uuid();
    PERFORM public.v32_append_ledger_transaction(v_tx,jsonb_build_array(
      jsonb_build_object('business_id',e.seller_business_id,'account_id',v_ar,'currency',e.currency,'debit_minor',e.total_minor,'credit_minor',0,'source_type','network_invoice','source_id',e.id),
      jsonb_build_object('business_id',e.seller_business_id,'account_id',v_revenue,'currency',e.currency,'debit_minor',0,'credit_minor',e.total_minor,'source_type','network_invoice','source_id',e.id)));
    UPDATE public.network_invoices SET status='settled',settled_at=now() WHERE id=e.id;
    SELECT dl.dispatch_id INTO v_dispatch FROM public.network_invoice_lines il JOIN public.network_order_dispatch_lines dl ON dl.id=il.dispatch_line_id WHERE il.invoice_id=e.id LIMIT 1;
    INSERT INTO public.network_dispatch_financial_clearances(dispatch_id,buyer_business_id,seller_business_id,state,settlement_batch_id,cleared_at) VALUES(v_dispatch,e.buyer_business_id,e.seller_business_id,'cleared',p_batch_id,now()) ON CONFLICT(dispatch_id) DO UPDATE SET state='cleared',settlement_batch_id=excluded.settlement_batch_id,cleared_at=excluded.cleared_at;
    v_total:=v_total+i.amount_minor;
  END LOOP;
  IF v_total <> b.total_minor THEN RAISE EXCEPTION 'batch total reconciliation mismatch'; END IF;
  -- Escrow funding: buyer Dr Escrow Asset / Cr Cash.
  v_tx:=gen_random_uuid();
  PERFORM public.v32_append_ledger_transaction(v_tx,jsonb_build_array(
    jsonb_build_object('business_id',b.buyer_business_id,'account_id',v_escrow,'currency',b.currency,'debit_minor',b.total_minor,'credit_minor',0,'source_type','settlement_batch','source_id',p_batch_id),
    jsonb_build_object('business_id',b.buyer_business_id,'account_id',v_cash,'currency',b.currency,'debit_minor',0,'credit_minor',b.total_minor,'source_type','settlement_batch','source_id',p_batch_id)));
  UPDATE public.multi_tenant_escrow_controls SET state='escrow_locked',escrow_locked_at=now() WHERE id=e.id;
  UPDATE public.settlement_batches SET state='escrow_locked',escrow_locked_at=now() WHERE id=b.id;
  -- Processing state is explicit and transactional.
  UPDATE public.multi_tenant_escrow_controls SET state='processing',processing_at=now() WHERE id=e.id;
  UPDATE public.settlement_batches SET state='processing',processing_at=now() WHERE id=b.id;
  -- Release: buyer Dr AP / Cr Escrow Asset; seller Dr Cash / Cr AR.
  v_tx:=gen_random_uuid();
  PERFORM public.v32_append_ledger_transaction(v_tx,jsonb_build_array(
    jsonb_build_object('business_id',b.buyer_business_id,'account_id',v_ap,'currency',b.currency,'debit_minor',b.total_minor,'credit_minor',0,'source_type','settlement_batch','source_id',p_batch_id),
    jsonb_build_object('business_id',b.buyer_business_id,'account_id',v_escrow,'currency',b.currency,'debit_minor',0,'credit_minor',b.total_minor,'source_type','settlement_batch','source_id',p_batch_id)));
  SELECT id INTO v_cash FROM public.financial_accounts WHERE business_id=b.seller_business_id AND account_code='CASH' AND currency=b.currency;
  SELECT id INTO v_ar FROM public.financial_accounts WHERE business_id=b.seller_business_id AND account_code='AR' AND currency=b.currency;
  v_tx:=gen_random_uuid();
  PERFORM public.v32_append_ledger_transaction(v_tx,jsonb_build_array(
    jsonb_build_object('business_id',b.seller_business_id,'account_id',v_cash,'currency',b.currency,'debit_minor',b.total_minor,'credit_minor',0,'source_type','settlement_batch','source_id',p_batch_id),
    jsonb_build_object('business_id',b.seller_business_id,'account_id',v_ar,'currency',b.currency,'debit_minor',0,'credit_minor',b.total_minor,'source_type','settlement_batch','source_id',p_batch_id)));
  UPDATE public.multi_tenant_escrow_controls SET state='settled',settled_at=now() WHERE id=e.id;
  UPDATE public.settlement_batches SET state='settled',settled_at=now() WHERE id=b.id;
  -- Reconciliation assertions: batch total, escrow zero, and every journal balanced within this transaction.
  IF EXISTS (SELECT 1 FROM public.financial_accounts WHERE id=v_escrow AND balance_minor <> 0) THEN RAISE EXCEPTION 'escrow account not reconciled to zero'; END IF;
  IF (SELECT coalesce(sum(amount_minor),0) FROM public.settlement_batch_lines WHERE settlement_batch_id=p_batch_id) <> b.total_minor THEN RAISE EXCEPTION 'settlement batch line total mismatch'; END IF;
  UPDATE public.multi_tenant_escrow_controls SET state='reconciled',reconciled_at=now(),state_hash=encode(extensions.digest(p_batch_id::text||'|reconciled|'||b.total_minor::text,'sha256'),'hex') WHERE id=e.id;
  UPDATE public.settlement_batches SET state='reconciled',reconciled_at=now() WHERE id=b.id;
  RETURN p_batch_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.reconcile_ingredient_yield_metrics()
RETURNS TABLE(audit_chain_ok boolean, ledger_chain_ok boolean, balanced_transaction_count bigint, unbalanced_transaction_count bigint, yield_efficiency_index numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE v_audit_bad bigint; v_ledger_bad bigint; v_bal bigint; v_unbal bigint; v_total_input numeric; v_total_output numeric;
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN RAISE EXCEPTION 'trusted executor required'; END IF;
  SELECT count(*) INTO v_audit_bad FROM (
    SELECT id, previous_hash, lag(event_hash) OVER (ORDER BY id) AS expected_previous FROM public.network_audit_stream
  ) x WHERE coalesce(previous_hash,'') <> coalesce(expected_previous,'') AND id <> (SELECT min(id) FROM public.network_audit_stream);
  SELECT count(*) INTO v_ledger_bad FROM (
    SELECT id, previous_entry_hash, lag(entry_hash) OVER (ORDER BY id) AS expected_previous FROM public.financial_ledger_entries
  ) x WHERE coalesce(previous_entry_hash,'') <> coalesce(expected_previous,'') AND id <> (SELECT min(id) FROM public.financial_ledger_entries);
  SELECT count(*) INTO v_bal FROM (SELECT transaction_id FROM public.financial_ledger_entries GROUP BY transaction_id HAVING sum(debit_minor)=sum(credit_minor) AND count(*)>=2) q;
  SELECT count(*) INTO v_unbal FROM (SELECT transaction_id FROM public.financial_ledger_entries GROUP BY transaction_id HAVING sum(debit_minor)<>sum(credit_minor) OR count(*)<2) q;
  SELECT coalesce(sum(g.received_quantity),0),coalesce(sum(g.received_quantity),0) INTO v_total_input,v_total_output FROM public.goods_receipt_lines g;
  RETURN QUERY SELECT v_audit_bad=0,v_ledger_bad=0,v_bal,v_unbal,CASE WHEN v_total_input=0 THEN 1::numeric ELSE round(v_total_output/v_total_input,8) END;
END;
$$;

-- Transparent tenant-scoped read access. All financial mutation is service-side through controlled functions.
ALTER TABLE public.financial_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.financial_ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.network_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.network_invoice_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.settlement_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.settlement_batch_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.multi_tenant_escrow_controls ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.network_dispatch_financial_clearances ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.financial_accounts,public.financial_ledger_entries,public.network_invoices,public.network_invoice_lines,public.settlement_batches,public.settlement_batch_lines,public.multi_tenant_escrow_controls,public.network_dispatch_financial_clearances FROM anon,authenticated;
GRANT SELECT ON TABLE public.financial_accounts,public.financial_ledger_entries,public.network_invoices,public.network_invoice_lines,public.settlement_batches,public.settlement_batch_lines,public.multi_tenant_escrow_controls,public.network_dispatch_financial_clearances TO authenticated;

CREATE POLICY financial_accounts_member_select ON public.financial_accounts FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.business_members bm WHERE bm.business_id=financial_accounts.business_id AND bm.user_id=(SELECT auth.uid())));
CREATE POLICY financial_ledger_member_select ON public.financial_ledger_entries FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.business_members bm WHERE bm.business_id=financial_ledger_entries.business_id AND bm.user_id=(SELECT auth.uid())));
CREATE POLICY network_invoices_party_select ON public.network_invoices FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.business_members bm WHERE bm.user_id=(SELECT auth.uid()) AND bm.business_id IN (network_invoices.buyer_business_id,network_invoices.seller_business_id)));
CREATE POLICY network_invoice_lines_party_select ON public.network_invoice_lines FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.network_invoices i JOIN public.business_members bm ON bm.business_id IN (i.buyer_business_id,i.seller_business_id) WHERE i.id=network_invoice_lines.invoice_id AND bm.user_id=(SELECT auth.uid())));
CREATE POLICY settlement_batches_party_select ON public.settlement_batches FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.business_members bm WHERE bm.user_id=(SELECT auth.uid()) AND bm.business_id IN (settlement_batches.buyer_business_id,settlement_batches.seller_business_id)));
CREATE POLICY settlement_batch_lines_party_select ON public.settlement_batch_lines FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.settlement_batches b JOIN public.business_members bm ON bm.business_id IN (b.buyer_business_id,b.seller_business_id) WHERE b.id=settlement_batch_lines.settlement_batch_id AND bm.user_id=(SELECT auth.uid())));
CREATE POLICY escrow_controls_party_select ON public.multi_tenant_escrow_controls FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.business_members bm WHERE bm.user_id=(SELECT auth.uid()) AND bm.business_id IN (multi_tenant_escrow_controls.buyer_business_id,multi_tenant_escrow_controls.seller_business_id)));
CREATE POLICY dispatch_financial_party_select ON public.network_dispatch_financial_clearances FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.business_members bm WHERE bm.user_id=(SELECT auth.uid()) AND bm.business_id IN (network_dispatch_financial_clearances.buyer_business_id,network_dispatch_financial_clearances.seller_business_id)));

REVOKE EXECUTE ON FUNCTION public.v32_is_trusted_executor() FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.v32_tenant_pair_lock(uuid,uuid) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.v32_financial_account_id(uuid,text,text) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.v32_append_ledger_transaction(uuid,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.v32_assert_settlement_line_clear(uuid) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.v32_three_way_match(uuid,uuid,uuid,integer) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.v32_compile_settlement_batch(uuid[]) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.clear_v32_settlement_batch(uuid) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.reconcile_ingredient_yield_metrics() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v32_three_way_match(uuid,uuid,uuid,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.v32_compile_settlement_batch(uuid[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.clear_v32_settlement_batch(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.reconcile_ingredient_yield_metrics() TO service_role;

COMMENT ON TABLE public.financial_accounts IS 'V3.2 tenant financial chart of accounts. Money is integer minor units.';
COMMENT ON TABLE public.financial_ledger_entries IS 'V3.2 append-only double-entry financial ledger with SHA-256 continuity.';
COMMENT ON TABLE public.network_invoices IS 'V3.2 immutable invoice header compiled only from matched operational evidence.';
COMMENT ON TABLE public.multi_tenant_escrow_controls IS 'V3.2 explicit settlement state machine: compiled -> escrow_locked -> processing -> settled -> reconciled.';