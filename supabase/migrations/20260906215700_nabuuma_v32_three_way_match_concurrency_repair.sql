CREATE OR REPLACE FUNCTION public.v32_three_way_match(p_po_line_id uuid, p_dispatch_line_id uuid, p_delivery_proof_id uuid, p_tax_rate_bps integer DEFAULT 0)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$
DECLARE
  po record;
  dl record;
  rc record;
  so record;
  d record;
  v_existing uuid;
  v_clear numeric;
  v_po_invoiced numeric;
  v_dispatch_invoiced numeric;
  v_sales_order_invoiced numeric;
  v_receipt_invoiced numeric;
  v_po_remaining numeric;
  v_dispatch_remaining numeric;
  v_sales_order_remaining numeric;
  v_receipt_remaining numeric;
  v_sub_numeric numeric;
  v_tax_numeric numeric;
  v_sub bigint;
  v_tax bigint;
  v_total bigint;
  v_invoice uuid;
  v_invoice_no text;
  v_currency text;
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN
    RAISE EXCEPTION 'trusted executor required';
  END IF;
  IF p_tax_rate_bps IS NULL OR p_tax_rate_bps < 0 OR p_tax_rate_bps > 10000 THEN
    RAISE EXCEPTION 'invalid tax rate';
  END IF;

  /*
   * The lock key covers the complete evidence tuple.  The source rows are
   * then explicitly locked before outstanding quantities are calculated.
   * PostgreSQL row locks block concurrent writers/lockers until transaction
   * end, which is required for a conservative three-way match.
   */
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'nabuuma:v32:match:' ||
      coalesce(p_po_line_id::text,'') || ':' ||
      coalesce(p_dispatch_line_id::text,'') || ':' ||
      coalesce(p_delivery_proof_id::text,''),
      3202
    )
  );

  SELECT i.id
  INTO v_existing
  FROM public.network_invoices i
  JOIN public.network_invoice_lines l ON l.invoice_id=i.id
  WHERE l.purchase_order_line_id=p_po_line_id
    AND l.dispatch_line_id=p_dispatch_line_id
    AND l.delivery_proof_id=p_delivery_proof_id
  LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO po
  FROM public.purchase_order_lines
  WHERE id=p_po_line_id
  FOR UPDATE;

  SELECT dl.*, d.sales_order_id, d.status AS dispatch_status,
         d.buyer_business_id AS dispatch_buyer,
         d.seller_business_id AS dispatch_seller
  INTO dl
  FROM public.network_order_dispatch_lines dl
  JOIN public.network_order_dispatches d ON d.id=dl.dispatch_id
  WHERE dl.id=p_dispatch_line_id
  FOR UPDATE;

  SELECT * INTO rc
  FROM public.network_dispatched_receipts
  WHERE id=p_delivery_proof_id
  FOR UPDATE;

  IF po.id IS NULL OR dl.id IS NULL OR rc.id IS NULL THEN
    RAISE EXCEPTION 'three-way evidence row missing';
  END IF;

  SELECT * INTO so
  FROM public.network_sales_order_lines
  WHERE id=dl.sales_order_line_id
  FOR UPDATE;

  SELECT * INTO d
  FROM public.network_order_dispatches
  WHERE id=dl.dispatch_id
  FOR UPDATE;

  IF so.id IS NULL OR d.id IS NULL THEN
    RAISE EXCEPTION 'sales order/dispatch relationship missing';
  END IF;
  IF dl.dispatch_id <> rc.dispatch_id THEN
    RAISE EXCEPTION 'delivery proof does not belong to dispatch';
  END IF;
  IF dl.buyer_business_id <> d.buyer_business_id
     OR dl.seller_business_id <> d.seller_business_id
     OR so.buyer_business_id <> d.buyer_business_id
     OR so.seller_business_id <> d.seller_business_id
     OR rc.buyer_business_id <> d.buyer_business_id
     OR rc.seller_business_id <> d.seller_business_id THEN
    RAISE EXCEPTION 'tenant party mismatch';
  END IF;
  IF so.ingredient_id IS DISTINCT FROM po.ingredient_id THEN
    RAISE EXCEPTION 'ingredient mismatch between PO and network order';
  END IF;
  IF lower(trim(po.unit)) <> lower(trim(dl.unit))
     OR lower(trim(dl.unit)) <> lower(trim(rc.unit))
     OR lower(trim(rc.unit)) <> lower(trim(so.unit)) THEN
    RAISE EXCEPTION 'exact unit mismatch';
  END IF;
  IF d.status <> 'delivered' THEN
    RAISE EXCEPTION 'dispatch must be delivered before invoice compilation';
  END IF;
  IF rc.receipt_status <> 'committed' THEN
    RAISE EXCEPTION 'delivery proof is not committed';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.network_dispatches_disputes x
    WHERE x.dispatch_id=d.id
      AND x.status IN ('open','under_review')
  ) THEN
    RAISE EXCEPTION 'dispatch has unresolved dispute';
  END IF;

  /*
   * Outstanding quantity is calculated independently for every evidence
   * node.  The prior implementation used greatest(received, invoiced) for
   * the PO side, which could overstate billable quantity when operational
   * receiving had already recorded more than the invoiced amount.
   */
  SELECT coalesce(sum(l.quantity),0) INTO v_po_invoiced
  FROM public.network_invoice_lines l
  WHERE l.purchase_order_line_id=po.id;

  SELECT coalesce(sum(l.quantity),0) INTO v_dispatch_invoiced
  FROM public.network_invoice_lines l
  WHERE l.dispatch_line_id=dl.id;

  SELECT coalesce(sum(l.quantity),0) INTO v_sales_order_invoiced
  FROM public.network_invoice_lines l
  WHERE l.invoice_id IS NOT NULL
    AND l.dispatch_line_id IN (
      SELECT x.id
      FROM public.network_order_dispatch_lines x
      WHERE x.sales_order_line_id=so.id
    );

  SELECT coalesce(sum(l.quantity),0) INTO v_receipt_invoiced
  FROM public.network_invoice_lines l
  WHERE l.delivery_proof_id=rc.id;

  v_po_remaining := po.ordered_quantity - greatest(v_po_invoiced,0);
  v_dispatch_remaining := dl.quantity - greatest(v_dispatch_invoiced,0);
  v_sales_order_remaining := so.quantity - greatest(v_sales_order_invoiced,0);
  v_receipt_remaining := rc.received_quantity - greatest(v_receipt_invoiced,0);

  v_clear := least(
    v_po_remaining,
    v_dispatch_remaining,
    v_sales_order_remaining,
    v_receipt_remaining
  );

  IF v_po_remaining < 0 OR v_dispatch_remaining < 0
     OR v_sales_order_remaining < 0 OR v_receipt_remaining < 0 THEN
    RAISE EXCEPTION 'existing invoice quantity exceeds source evidence quantity';
  END IF;
  IF v_clear <= 0 THEN
    RAISE EXCEPTION 'no clear quantity remains';
  END IF;

  v_sub_numeric := v_clear * so.unit_price_minor::numeric;
  IF v_sub_numeric <> trunc(v_sub_numeric) THEN
    RAISE EXCEPTION 'fractional minor-unit subtotal is not permitted';
  END IF;
  v_sub := v_sub_numeric::bigint;

  v_tax_numeric := round(v_sub_numeric * p_tax_rate_bps::numeric / 10000,0);
  IF v_tax_numeric <> trunc(v_tax_numeric) THEN
    RAISE EXCEPTION 'tax rounding did not produce an integer minor unit';
  END IF;
  v_tax := v_tax_numeric::bigint;
  v_total := v_sub + v_tax;

  v_currency := (SELECT currency FROM public.network_sales_orders WHERE id=so.sales_order_id);
  IF v_currency IS NULL OR length(v_currency) <> 3 THEN
    RAISE EXCEPTION 'invalid sales-order currency';
  END IF;

  v_invoice := gen_random_uuid();
  v_invoice_no := 'NAB-V32-' || upper(replace(v_invoice::text,'-',''));

  PERFORM set_config('nabuuma.v32_building_invoice','1',true);
  INSERT INTO public.network_invoices(
    id,invoice_number,buyer_business_id,seller_business_id,currency,
    subtotal_minor,tax_minor,total_minor
  )
  VALUES(
    v_invoice,v_invoice_no,d.buyer_business_id,d.seller_business_id,v_currency,
    v_sub,v_tax,v_total
  );

  INSERT INTO public.network_invoice_lines(
    invoice_id,purchase_order_line_id,dispatch_line_id,delivery_proof_id,
    ingredient_id,quantity,unit,unit_price_minor,subtotal_minor,tax_rate_bps,
    tax_minor,total_minor
  )
  VALUES(
    v_invoice,po.id,dl.id,rc.id,po.ingredient_id,v_clear,po.unit,
    so.unit_price_minor,v_sub,p_tax_rate_bps,v_tax,v_total
  );

  UPDATE public.network_invoices
  SET immutable_block_hash=public.v32_invoice_hash(v_invoice)
  WHERE id=v_invoice;

  PERFORM set_config('nabuuma.v32_building_invoice','0',true);
  RETURN v_invoice;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('nabuuma.v32_building_invoice','0',true);
  RAISE;
END;
$function$;

REVOKE ALL ON FUNCTION public.v32_three_way_match(uuid,uuid,uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.v32_three_way_match(uuid,uuid,uuid,integer) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v32_three_way_match(uuid,uuid,uuid,integer) TO service_role;
