-- V3.2 post-deployment forensic correction: fix idempotency, invoice lifecycle immutability, settlement accounting counters, and reconciliation metric semantics.

CREATE OR REPLACE FUNCTION public.v32_invoice_hash(p_invoice uuid)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public, extensions, pg_temp
AS $$
  SELECT encode(extensions.digest(
    jsonb_build_object(
      'invoice_id',i.id,
      'invoice_number',i.invoice_number,
      'buyer_business_id',i.buyer_business_id,
      'seller_business_id',i.seller_business_id,
      'currency',i.currency,
      'subtotal_minor',i.subtotal_minor,
      'tax_minor',i.tax_minor,
      'total_minor',i.total_minor,
      'lines',coalesce((SELECT jsonb_agg(jsonb_build_object(
          'id',l.id,
          'purchase_order_line_id',l.purchase_order_line_id,
          'dispatch_line_id',l.dispatch_line_id,
          'delivery_proof_id',l.delivery_proof_id,
          'ingredient_id',l.ingredient_id,
          'quantity',l.quantity,
          'unit',l.unit,
          'unit_price_minor',l.unit_price_minor,
          'subtotal_minor',l.subtotal_minor,
          'tax_rate_bps',l.tax_rate_bps,
          'tax_minor',l.tax_minor,
          'total_minor',l.total_minor
        ) ORDER BY l.id) FROM public.network_invoice_lines l WHERE l.invoice_id=i.id),'[]'::jsonb)
    )::text,'sha256'),'hex')
  FROM public.network_invoices i WHERE i.id=p_invoice;
$$;

CREATE OR REPLACE FUNCTION public.v32_invoice_immutable_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'invoice history is immutable; use adjustment documents';
  END IF;
  IF TG_TABLE_NAME='network_invoice_lines' THEN
    IF coalesce(current_setting('nabuuma.v32_building_invoice',true),'0') <> '1' THEN
      RAISE EXCEPTION 'invoice lines are immutable; use adjustment documents';
    END IF;
    RETURN NEW;
  END IF;
  IF coalesce(current_setting('nabuuma.v32_building_invoice',true),'0')='1' THEN RETURN NEW; END IF;
  IF coalesce(current_setting('nabuuma.v32_settling_invoice',true),'0')='1'
     AND NEW.id=OLD.id
     AND NEW.invoice_number=OLD.invoice_number
     AND NEW.buyer_business_id=OLD.buyer_business_id
     AND NEW.seller_business_id=OLD.seller_business_id
     AND NEW.currency=OLD.currency
     AND NEW.subtotal_minor=OLD.subtotal_minor
     AND NEW.tax_minor=OLD.tax_minor
     AND NEW.total_minor=OLD.total_minor
     AND NEW.immutable_block_hash=OLD.immutable_block_hash
     AND NEW.created_at=OLD.created_at
     AND NEW.compiled_at=OLD.compiled_at
     AND NEW.status IN ('compiled','settled','voided')
     AND (NEW.status=OLD.status OR (OLD.status='compiled' AND NEW.status='settled'))
     AND (NEW.status=OLD.status OR NEW.settled_at IS NOT NULL) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'invoice commercial fields are immutable; use adjustment documents';
END;
$$;

CREATE OR REPLACE FUNCTION public.v32_three_way_match(p_po_line_id uuid,p_dispatch_line_id uuid,p_delivery_proof_id uuid,p_tax_rate_bps integer DEFAULT 0)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE po record; dl record; rc record; so record; d record; v_existing uuid; v_clear numeric; v_already_po numeric; v_already_receipt numeric; v_sub_numeric numeric; v_tax_numeric numeric; v_sub bigint; v_tax bigint; v_total bigint; v_invoice uuid; v_invoice_no text; v_currency text;
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN RAISE EXCEPTION 'trusted executor required'; END IF;
  IF p_tax_rate_bps IS NULL OR p_tax_rate_bps < 0 OR p_tax_rate_bps > 10000 THEN RAISE EXCEPTION 'invalid tax rate'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('nabuuma:v32:match:'||coalesce(p_po_line_id::text,'')||':'||coalesce(p_dispatch_line_id::text,'')||':'||coalesce(p_delivery_proof_id::text,''),3202));
  SELECT i.id INTO v_existing FROM public.network_invoices i JOIN public.network_invoice_lines l ON l.invoice_id=i.id WHERE l.purchase_order_line_id=p_po_line_id AND l.dispatch_line_id=p_dispatch_line_id AND l.delivery_proof_id=p_delivery_proof_id LIMIT 1;
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
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
DECLARE v_batch uuid:=gen_random_uuid(); v_buyer uuid; v_seller uuid; v_currency text; v_total bigint; v_invoice uuid; v_number text; v_distinct integer;
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN RAISE EXCEPTION 'trusted executor required'; END IF;
  IF p_invoice_ids IS NULL OR cardinality(p_invoice_ids)=0 THEN RAISE EXCEPTION 'invoice list is empty'; END IF;
  SELECT count(DISTINCT x) INTO v_distinct FROM unnest(p_invoice_ids) x;
  IF v_distinct <> cardinality(p_invoice_ids) THEN RAISE EXCEPTION 'duplicate invoice ids in settlement batch'; END IF;
  SELECT buyer_business_id,seller_business_id,currency INTO v_buyer,v_seller,v_currency FROM public.network_invoices WHERE id=p_invoice_ids[1] FOR UPDATE;
  IF v_buyer IS NULL THEN RAISE EXCEPTION 'first invoice missing'; END IF;
  PERFORM public.v32_tenant_pair_lock(v_buyer,v_seller);
  IF EXISTS (SELECT 1 FROM public.network_invoices i WHERE i.id=ANY(p_invoice_ids) AND (i.status <> 'compiled' OR i.buyer_business_id<>v_buyer OR i.seller_business_id<>v_seller OR i.currency<>v_currency)) THEN RAISE EXCEPTION 'invoice set is not homogeneous and clearable'; END IF;
  SELECT coalesce(sum(i.total_minor),0) INTO v_total FROM public.network_invoices i WHERE i.id=ANY(p_invoice_ids);
  IF v_total <= 0 THEN RAISE EXCEPTION 'settlement total must be positive'; END IF;
  IF EXISTS (SELECT 1 FROM public.settlement_batch_lines s WHERE s.invoice_id=ANY(p_invoice_ids)) THEN RAISE EXCEPTION 'one or more invoices already belong to a settlement batch'; END IF;
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
DECLARE b record; e record; i record; inv record; v_cash uuid; v_escrow uuid; v_ap uuid; v_expense uuid; v_ar uuid; v_revenue uuid; v_tx uuid; v_cash_balance bigint; v_processed_total bigint:=0; v_dispatch uuid;
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN RAISE EXCEPTION 'trusted executor required'; END IF;
  SELECT * INTO b FROM public.settlement_batches WHERE id=p_batch_id FOR UPDATE;
  IF b.id IS NULL THEN RAISE EXCEPTION 'settlement batch not found'; END IF;
  PERFORM public.v32_tenant_pair_lock(b.buyer_business_id,b.seller_business_id);
  SELECT * INTO e FROM public.multi_tenant_escrow_controls WHERE settlement_batch_id=p_batch_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'escrow control not found'; END IF;
  IF b.state='reconciled' THEN RETURN p_batch_id; END IF;
  IF b.state <> 'compiled' OR e.state <> 'compiled' THEN RAISE EXCEPTION 'batch and escrow must both be compiled before clearing'; END IF;
  PERFORM public.v32_financial_account_id(b.buyer_business_id,'CASH',b.currency);
  PERFORM public.v32_financial_account_id(b.buyer_business_id,'ESCROW_ASSET',b.currency);
  PERFORM public.v32_financial_account_id(b.buyer_business_id,'AP',b.currency);
  PERFORM public.v32_financial_account_id(b.buyer_business_id,'EXPENSE',b.currency);
  PERFORM public.v32_financial_account_id(b.seller_business_id,'CASH',b.currency);
  PERFORM public.v32_financial_account_id(b.seller_business_id,'AR',b.currency);
  PERFORM public.v32_financial_account_id(b.seller_business_id,'REVENUE',b.currency);
  SELECT balance_minor,id INTO v_cash_balance,v_cash FROM public.financial_accounts WHERE business_id=b.buyer_business_id AND account_code='CASH' AND currency=b.currency FOR UPDATE;
  IF coalesce(v_cash_balance,0) < b.total_minor THEN RAISE EXCEPTION 'insufficient buyer cash: available %, required %',coalesce(v_cash_balance,0),b.total_minor; END IF;
  SELECT id INTO v_escrow FROM public.financial_accounts WHERE business_id=b.buyer_business_id AND account_code='ESCROW_ASSET' AND currency=b.currency FOR UPDATE;
  SELECT id INTO v_ap FROM public.financial_accounts WHERE business_id=b.buyer_business_id AND account_code='AP' AND currency=b.currency FOR UPDATE;
  SELECT id INTO v_expense FROM public.financial_accounts WHERE business_id=b.buyer_business_id AND account_code='EXPENSE' AND currency=b.currency FOR UPDATE;
  FOR i IN SELECT * FROM public.settlement_batch_lines WHERE settlement_batch_id=p_batch_id ORDER BY id FOR UPDATE LOOP
    SELECT * INTO inv FROM public.network_invoices WHERE id=i.invoice_id FOR UPDATE;
    IF inv.status <> 'compiled' THEN RAISE EXCEPTION 'invoice % is not compiled',inv.id; END IF;
    PERFORM public.v32_assert_settlement_line_clear(inv.id);
    v_tx:=gen_random_uuid();
    PERFORM public.v32_append_ledger_transaction(v_tx,jsonb_build_array(
      jsonb_build_object('business_id',inv.buyer_business_id,'account_id',v_expense,'currency',inv.currency,'debit_minor',inv.total_minor,'credit_minor',0,'source_type','network_invoice','source_id',inv.id),
      jsonb_build_object('business_id',inv.buyer_business_id,'account_id',v_ap,'currency',inv.currency,'debit_minor',0,'credit_minor',inv.total_minor,'source_type','network_invoice','source_id',inv.id)));
    SELECT id INTO v_ar FROM public.financial_accounts WHERE business_id=inv.seller_business_id AND account_code='AR' AND currency=inv.currency FOR UPDATE;
    SELECT id INTO v_revenue FROM public.financial_accounts WHERE business_id=inv.seller_business_id AND account_code='REVENUE' AND currency=inv.currency FOR UPDATE;
    v_tx:=gen_random_uuid();
    PERFORM public.v32_append_ledger_transaction(v_tx,jsonb_build_array(
      jsonb_build_object('business_id',inv.seller_business_id,'account_id',v_ar,'currency',inv.currency,'debit_minor',inv.total_minor,'credit_minor',0,'source_type','network_invoice','source_id',inv.id),
      jsonb_build_object('business_id',inv.seller_business_id,'account_id',v_revenue,'currency',inv.currency,'debit_minor',0,'credit_minor',inv.total_minor,'source_type','network_invoice','source_id',inv.id)));
    PERFORM set_config('nabuuma.v32_settling_invoice','1',true);
    UPDATE public.network_invoices SET status='settled',settled_at=now() WHERE id=inv.id;
    PERFORM set_config('nabuuma.v32_settling_invoice','0',true);
    SELECT dl.dispatch_id INTO v_dispatch FROM public.network_invoice_lines il JOIN public.network_order_dispatch_lines dl ON dl.id=il.dispatch_line_id WHERE il.invoice_id=inv.id LIMIT 1;
    INSERT INTO public.network_dispatch_financial_clearances(dispatch_id,buyer_business_id,seller_business_id,state,settlement_batch_id,cleared_at) VALUES(v_dispatch,inv.buyer_business_id,inv.seller_business_id,'cleared',p_batch_id,now()) ON CONFLICT(dispatch_id) DO UPDATE SET state='cleared',settlement_batch_id=excluded.settlement_batch_id,cleared_at=excluded.cleared_at;
    v_processed_total:=v_processed_total+i.amount_minor;
  END LOOP;
  IF v_processed_total <> b.total_minor THEN RAISE EXCEPTION 'batch total reconciliation mismatch: processed %, expected %',v_processed_total,b.total_minor; END IF;
  v_tx:=gen_random_uuid();
  PERFORM public.v32_append_ledger_transaction(v_tx,jsonb_build_array(
    jsonb_build_object('business_id',b.buyer_business_id,'account_id',v_escrow,'currency',b.currency,'debit_minor',b.total_minor,'credit_minor',0,'source_type','settlement_batch','source_id',p_batch_id),
    jsonb_build_object('business_id',b.buyer_business_id,'account_id',v_cash,'currency',b.currency,'debit_minor',0,'credit_minor',b.total_minor,'source_type','settlement_batch','source_id',p_batch_id)));
  UPDATE public.multi_tenant_escrow_controls SET state='escrow_locked',escrow_locked_at=now() WHERE id=e.id;
  UPDATE public.settlement_batches SET state='escrow_locked',escrow_locked_at=now() WHERE id=b.id;
  UPDATE public.multi_tenant_escrow_controls SET state='processing',processing_at=now() WHERE id=e.id;
  UPDATE public.settlement_batches SET state='processing',processing_at=now() WHERE id=b.id;
  v_tx:=gen_random_uuid();
  PERFORM public.v32_append_ledger_transaction(v_tx,jsonb_build_array(
    jsonb_build_object('business_id',b.buyer_business_id,'account_id',v_ap,'currency',b.currency,'debit_minor',b.total_minor,'credit_minor',0,'source_type','settlement_batch','source_id',p_batch_id),
    jsonb_build_object('business_id',b.buyer_business_id,'account_id',v_escrow,'currency',b.currency,'debit_minor',0,'credit_minor',b.total_minor,'source_type','settlement_batch','source_id',p_batch_id)));
  SELECT id INTO v_cash FROM public.financial_accounts WHERE business_id=b.seller_business_id AND account_code='CASH' AND currency=b.currency FOR UPDATE;
  SELECT id INTO v_ar FROM public.financial_accounts WHERE business_id=b.seller_business_id AND account_code='AR' AND currency=b.currency FOR UPDATE;
  v_tx:=gen_random_uuid();
  PERFORM public.v32_append_ledger_transaction(v_tx,jsonb_build_array(
    jsonb_build_object('business_id',b.seller_business_id,'account_id',v_cash,'currency',b.currency,'debit_minor',b.total_minor,'credit_minor',0,'source_type','settlement_batch','source_id',p_batch_id),
    jsonb_build_object('business_id',b.seller_business_id,'account_id',v_ar,'currency',b.currency,'debit_minor',0,'credit_minor',b.total_minor,'source_type','settlement_batch','source_id',p_batch_id)));
  UPDATE public.multi_tenant_escrow_controls SET state='settled',settled_at=now() WHERE id=e.id;
  UPDATE public.settlement_batches SET state='settled',settled_at=now() WHERE id=b.id;
  IF (SELECT balance_minor FROM public.financial_accounts WHERE id=v_escrow) <> 0 THEN RAISE EXCEPTION 'escrow account not reconciled to zero'; END IF;
  IF (SELECT coalesce(sum(amount_minor),0) FROM public.settlement_batch_lines WHERE settlement_batch_id=p_batch_id) <> b.total_minor THEN RAISE EXCEPTION 'settlement batch line total mismatch'; END IF;
  UPDATE public.multi_tenant_escrow_controls SET state='reconciled',reconciled_at=now(),state_hash=encode(extensions.digest(p_batch_id::text||'|reconciled|'||b.total_minor::text,'sha256'),'hex') WHERE id=e.id;
  UPDATE public.settlement_batches SET state='reconciled',reconciled_at=now() WHERE id=b.id;
  RETURN p_batch_id;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('nabuuma.v32_settling_invoice','0',true);
  RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION public.reconcile_ingredient_yield_metrics()
RETURNS TABLE(audit_chain_ok boolean, ledger_chain_ok boolean, balanced_transaction_count bigint, unbalanced_transaction_count bigint, yield_efficiency_index numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE v_audit_bad bigint; v_ledger_bad bigint; v_bal bigint; v_unbal bigint; v_received numeric; v_waste numeric;
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN RAISE EXCEPTION 'trusted executor required'; END IF;
  SELECT count(*) INTO v_audit_bad FROM (SELECT id,previous_hash,lag(event_hash) OVER (ORDER BY id) expected_previous FROM public.network_audit_stream) x WHERE id<>(SELECT min(id) FROM public.network_audit_stream) AND coalesce(previous_hash,'')<>coalesce(expected_previous,'');
  SELECT count(*) INTO v_ledger_bad FROM (SELECT id,previous_entry_hash,lag(entry_hash) OVER (ORDER BY id) expected_previous FROM public.financial_ledger_entries) x WHERE id<>(SELECT min(id) FROM public.financial_ledger_entries) AND coalesce(previous_entry_hash,'')<>coalesce(expected_previous,'');
  SELECT count(*) INTO v_bal FROM (SELECT transaction_id FROM public.financial_ledger_entries GROUP BY transaction_id HAVING sum(debit_minor)=sum(credit_minor) AND count(*)>=2) q;
  SELECT count(*) INTO v_unbal FROM (SELECT transaction_id FROM public.financial_ledger_entries GROUP BY transaction_id HAVING sum(debit_minor)<>sum(credit_minor) OR count(*)<2) q;
  SELECT coalesce(sum(received_quantity),0) INTO v_received FROM public.goods_receipt_lines;
  SELECT coalesce(sum(w.quantity),0) INTO v_waste FROM public.waste_records w WHERE w.quantity IS NOT NULL AND EXISTS (SELECT 1 FROM public.goods_receipt_lines g WHERE g.ingredient_id=w.ingredient_id AND lower(coalesce(g.unit,''))=lower(coalesce(w.unit,'')));
  RETURN QUERY SELECT v_audit_bad=0,v_ledger_bad=0,v_bal,v_unbal,CASE WHEN v_received<=0 THEN NULL::numeric ELSE greatest(0::numeric,least(1::numeric,round((v_received-v_waste)/v_received,8))) END;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.v32_invoice_hash(uuid) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.v32_invoice_immutable_guard() FROM PUBLIC,anon,authenticated;