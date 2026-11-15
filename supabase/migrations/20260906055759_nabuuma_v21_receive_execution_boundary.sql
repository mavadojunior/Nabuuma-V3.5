CREATE OR REPLACE FUNCTION public.v21_execute_stock_transfer_receive(p_transfer_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
declare
  t record;
  bl record;
  source_batch record;
  existing_batch_id uuid;
  tx uuid := gen_random_uuid();
  receipt_hash text;
  actor uuid := auth.uid();
  line_count bigint := 0;
  movement_count bigint := 0;
begin
  if auth.role() not in ('service_role','postgres') then
    raise exception 'trusted execution role required';
  end if;

  select * into t from public.stock_transfers where id=p_transfer_id for update;
  if not found then raise exception 'stock transfer not found'; end if;
  if t.status='received' then return p_transfer_id; end if;
  if t.status <> 'in_transit' then
    raise exception 'stock transfer must be in_transit before receive';
  end if;

  for bl in
    select * from public.stock_transfer_batch_lines
    where stock_transfer_line_id in (
      select id from public.stock_transfer_lines where stock_transfer_id=p_transfer_id
    )
      and business_id=t.business_id
    order by id
    for update
  loop
    if bl.quantity <= 0 then raise exception 'received batch quantity must be positive'; end if;

    select ib.* into source_batch
    from public.ingredient_batches ib
    where ib.id=bl.source_batch_id
      and ib.business_id=t.business_id
      and ib.location_id=t.source_location_id
    for update;
    if not found then
      raise exception 'source batch % not found for transfer receipt', bl.source_batch_id;
    end if;

    if source_batch.unit <> bl.unit then
      raise exception 'exact-unit violation for batch %', bl.source_batch_id;
    end if;

    select ib.id into existing_batch_id
    from public.ingredient_batches ib
    where ib.business_id=t.business_id
      and ib.location_id=t.destination_location_id
      and ib.batch_id=source_batch.batch_id
      and ib.batch_code=source_batch.batch_code
      and ib.unit=bl.unit
      and coalesce(ib.expiry_date,'9999-12-31'::date)=coalesce(source_batch.expiry_date,'9999-12-31'::date)
    order by ib.created_at desc, ib.id
    limit 1
    for update;

    if existing_batch_id is null then
      insert into public.ingredient_batches(
        id,batch_id,business_id,ingredient_id,location_id,batch_code,received_at,expiry_date,remaining_quantity,unit,created_at,updated_at
      ) values (
        gen_random_uuid(),source_batch.batch_id,t.business_id,source_batch.ingredient_id,t.destination_location_id,
        source_batch.batch_code,source_batch.received_at,source_batch.expiry_date,bl.quantity,bl.unit,now(),now()
      );
    else
      update public.ingredient_batches
      set remaining_quantity=remaining_quantity+bl.quantity, updated_at=now()
      where id=existing_batch_id;
    end if;

    insert into public.inventory_movements(
      business_id,ingredient_id,location_id,quantity,unit,reason,reference_id,created_at
    ) values (
      t.business_id,source_batch.ingredient_id,t.destination_location_id,bl.quantity,bl.unit,
      'STOCK_TRANSFER_RECEIPT',p_transfer_id,now()
    );
    movement_count := movement_count+1;
  end loop;

  select count(*) into line_count
  from public.stock_transfer_batch_lines bl
  where bl.stock_transfer_line_id in (
    select id from public.stock_transfer_lines where stock_transfer_id=p_transfer_id
  ) and bl.business_id=t.business_id;

  if line_count=0 then raise exception 'stock transfer has no dispatched batch lines'; end if;

  update public.stock_transfers
  set status='received', received_at=coalesce(received_at,now()), received_by=actor
  where id=p_transfer_id;

  receipt_hash := encode(digest(p_transfer_id::text||'|'||tx::text||'|'||line_count::text||'|'||movement_count::text,'sha256'),'hex');
  perform public.v21_record_execution_receipt(t.business_id,tx,'STOCK_TRANSFER_RECEIPT',receipt_hash);
  return p_transfer_id;
end;
$function$;

REVOKE ALL ON FUNCTION public.v21_execute_stock_transfer_receive(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v21_execute_stock_transfer_receive(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.v21_execute_stock_transfer(p_transfer_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
declare
  t record;
  l record;
  batch record;
  remaining numeric;
  moved numeric;
  tx uuid := gen_random_uuid();
  receipt_hash text;
  actor uuid := auth.uid();
  line_count bigint := 0;
begin
  if auth.role() not in ('service_role','postgres') then raise exception 'trusted execution role required'; end if;
  select * into t from public.stock_transfers where id=p_transfer_id for update;
  if not found then raise exception 'stock transfer not found'; end if;
  if t.status in ('in_transit','received','cancelled') then return p_transfer_id; end if;
  if t.status not in ('draft','approved') then raise exception 'stock transfer is not dispatchable in current state'; end if;
  if t.source_location_id=t.destination_location_id then raise exception 'source and destination locations must differ'; end if;

  for l in select * from public.stock_transfer_lines where stock_transfer_id=p_transfer_id order by id for update loop
    perform public.v19_assert_exact_unit(l.unit);
    remaining := l.quantity;
    if remaining <= 0 then raise exception 'transfer quantity must be positive'; end if;

    for batch in
      select * from public.ingredient_batches
      where business_id=t.business_id and ingredient_id=l.ingredient_id and location_id=t.source_location_id
        and remaining_quantity > 0 and (expiry_date is null or expiry_date >= current_date)
        and unit=l.unit
      order by expiry_date nulls last, received_at, id
      for update
    loop
      exit when remaining <= 0;
      moved := least(remaining,batch.remaining_quantity);
      update public.ingredient_batches set remaining_quantity=remaining_quantity-moved,updated_at=now() where id=batch.id;
      insert into public.stock_transfer_batch_lines(
        id,business_id,stock_transfer_line_id,source_batch_id,batch_code,expiry_date,quantity,unit,created_at
      ) values (
        gen_random_uuid(),t.business_id,l.id,batch.id,batch.batch_code,batch.expiry_date,moved,batch.unit,now()
      );
      insert into public.inventory_movements(
        business_id,ingredient_id,location_id,quantity,unit,reason,reference_id,created_at
      ) values (
        t.business_id,l.ingredient_id,t.source_location_id,-moved,batch.unit,'STOCK_TRANSFER_DISPATCH',p_transfer_id,now()
      );
      remaining := remaining-moved;
    end loop;
    if remaining > 0 then raise exception 'insufficient exact-unit FEFO stock for ingredient %',l.ingredient_id; end if;
    line_count := line_count+1;
  end loop;

  if line_count=0 then raise exception 'stock transfer has no lines'; end if;
  update public.stock_transfers set status='in_transit',dispatched_at=coalesce(dispatched_at,now()),dispatched_by=actor where id=p_transfer_id;
  receipt_hash := encode(digest(p_transfer_id::text||'|'||tx::text||'|'||line_count::text,'sha256'),'hex');
  perform public.v21_record_execution_receipt(t.business_id,tx,'STOCK_TRANSFER_DISPATCH',receipt_hash);
  return p_transfer_id;
end;
$function$;

REVOKE ALL ON FUNCTION public.v21_execute_stock_transfer(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v21_execute_stock_transfer(uuid) TO service_role;