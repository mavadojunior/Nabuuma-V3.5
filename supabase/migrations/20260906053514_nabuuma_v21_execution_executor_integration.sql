begin;

create or replace function public.v21_execute_stock_transfer(p_transfer_id uuid)
returns uuid
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  t record;
  l record;
  batch record;
  available_qty numeric;
  remaining numeric;
  moved numeric;
  tx uuid := gen_random_uuid();
  receipt_hash text;
  actor uuid := auth.uid();
  line_count bigint := 0;
begin
  if auth.role() not in ('service_role','postgres') then
    raise exception 'trusted execution role required';
  end if;
  select * into t from public.stock_transfers where id=p_transfer_id for update;
  if not found then raise exception 'stock transfer not found'; end if;
  if t.status in ('completed','received','cancelled') then
    return p_transfer_id;
  end if;
  if t.source_location_id=t.destination_location_id then
    raise exception 'source and destination locations must differ';
  end if;

  for l in select * from public.stock_transfer_lines where stock_transfer_id=p_transfer_id order by id for update loop
    remaining := l.quantity;
    if remaining <= 0 then raise exception 'transfer quantity must be positive'; end if;

    for batch in
      select * from public.ingredient_batches
      where business_id=t.business_id
        and ingredient_id=l.ingredient_id
        and location_id=t.source_location_id
        and remaining_quantity > 0
        and (expiry_date is null or expiry_date >= current_date)
      order by expiry_date nulls last, received_at, id
      for update
    loop
      exit when remaining <= 0;
      moved := least(remaining,batch.remaining_quantity);
      update public.ingredient_batches
        set remaining_quantity=remaining_quantity-moved, updated_at=now()
        where id=batch.id;
      insert into public.ingredient_batches(id,batch_id,business_id,ingredient_id,location_id,batch_code,received_at,expiry_date,remaining_quantity,unit,created_at,updated_at)
      values(gen_random_uuid(),batch.batch_id,t.business_id,batch.ingredient_id,t.destination_location_id,batch.batch_code,batch.received_at,batch.expiry_date,moved,batch.unit,now(),now());
      remaining := remaining-moved;
    end loop;
    if remaining > 0 then raise exception 'insufficient exact-unit FEFO stock for ingredient %',l.ingredient_id; end if;
    line_count := line_count+1;
  end loop;

  if line_count=0 then raise exception 'stock transfer has no lines'; end if;
  update public.stock_transfers set status='completed' where id=p_transfer_id;
  receipt_hash := encode(digest(p_transfer_id::text||'|'||tx::text||'|'||line_count::text,'sha256'),'hex');
  perform public.v21_record_execution_receipt(t.business_id,tx,'STOCK_TRANSFER',receipt_hash);
  return p_transfer_id;
exception when others then
  raise;
end;
$$;

revoke all on function public.v21_execute_stock_transfer(uuid) from public,anon,authenticated;
grant execute on function public.v21_execute_stock_transfer(uuid) to service_role;

commit;