CREATE OR REPLACE FUNCTION public.v21_execute_stock_transfer(p_transfer_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
declare
  t record;
  l record;
  batch record;
  remaining numeric;
  moved numeric;
  tx uuid := gen_random_uuid();
  receipt_hash text;
  line_count bigint := 0;
begin
  IF auth.role() NOT IN ('service_role','postgres') THEN
    RAISE EXCEPTION 'trusted execution role required';
  END IF;

  SELECT * INTO t FROM public.stock_transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'stock transfer not found'; END IF;
  IF t.status IN ('in_transit','received','cancelled') THEN RETURN p_transfer_id; END IF;
  IF t.status NOT IN ('draft','approved') THEN RAISE EXCEPTION 'stock transfer is not executable from status %', t.status; END IF;
  IF t.source_location_id = t.destination_location_id THEN RAISE EXCEPTION 'source and destination locations must differ'; END IF;

  FOR l IN
    SELECT * FROM public.stock_transfer_lines
    WHERE stock_transfer_id = p_transfer_id
    ORDER BY id
    FOR UPDATE
  LOOP
    remaining := l.quantity;
    IF remaining <= 0 THEN RAISE EXCEPTION 'transfer quantity must be positive'; END IF;

    FOR batch IN
      SELECT * FROM public.ingredient_batches
      WHERE business_id = t.business_id
        AND ingredient_id = l.ingredient_id
        AND location_id = t.source_location_id
        AND remaining_quantity > 0
        AND (expiry_date IS NULL OR expiry_date >= current_date)
        AND unit = l.unit
      ORDER BY expiry_date NULLS LAST, received_at, id
      FOR UPDATE
    LOOP
      EXIT WHEN remaining <= 0;
      moved := LEAST(remaining, batch.remaining_quantity);

      UPDATE public.ingredient_batches
      SET remaining_quantity = remaining_quantity - moved, updated_at = now()
      WHERE id = batch.id;

      INSERT INTO public.stock_transfer_batch_lines
        (business_id, stock_transfer_line_id, source_batch_id, batch_code, expiry_date, quantity, unit)
      VALUES
        (t.business_id, l.id, batch.id, batch.batch_code, batch.expiry_date, moved, batch.unit);

      remaining := remaining - moved;
    END LOOP;

    IF remaining > 0 THEN
      RAISE EXCEPTION 'insufficient exact-unit FEFO stock for ingredient %', l.ingredient_id;
    END IF;
    line_count := line_count + 1;
  END LOOP;

  IF line_count = 0 THEN RAISE EXCEPTION 'stock transfer has no lines'; END IF;

  UPDATE public.stock_transfers
  SET status = 'in_transit', dispatched_at = COALESCE(dispatched_at, now())
  WHERE id = p_transfer_id;

  receipt_hash := encode(digest(p_transfer_id::text || '|' || tx::text || '|' || line_count::text, 'sha256'), 'hex');
  PERFORM public.v21_record_execution_receipt(t.business_id, tx, 'STOCK_TRANSFER_DISPATCH', receipt_hash);
  RETURN p_transfer_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.v21_execute_stock_transfer(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v21_execute_stock_transfer(uuid) TO service_role;
