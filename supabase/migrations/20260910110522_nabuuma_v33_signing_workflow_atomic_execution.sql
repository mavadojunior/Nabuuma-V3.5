create or replace function public.v33_record_signature(
  p_workflow_id uuid,
  p_signer_user_id uuid,
  p_key_registry_id uuid,
  p_signature_digest text,
  p_signed_payload_digest text
) returns table(status text, collected_signatures integer, required_signatures integer)
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare
  v_workflow public.network_signing_workflows%rowtype;
  v_key public.network_root_key_registry%rowtype;
  v_count integer;
begin
  if p_signature_digest is null or length(btrim(p_signature_digest)) < 16 then
    raise exception 'signature digest is required and must be at least 16 characters';
  end if;
  if p_signed_payload_digest is null or length(btrim(p_signed_payload_digest)) < 16 then
    raise exception 'signed payload digest is required and must be at least 16 characters';
  end if;

  select * into v_workflow
  from public.network_signing_workflows
  where id = p_workflow_id
  for update;
  if not found then raise exception 'signing workflow % does not exist', p_workflow_id; end if;
  if v_workflow.status <> 'pending' then
    raise exception 'signing workflow % is not pending', p_workflow_id;
  end if;
  if v_workflow.expires_at is not null and v_workflow.expires_at <= clock_timestamp() then
    update public.network_signing_workflows set status='expired' where id=p_workflow_id;
    raise exception 'signing workflow % has expired', p_workflow_id;
  end if;
  if v_workflow.required_signatures < 1 then
    raise exception 'signing workflow % has invalid required signature threshold', p_workflow_id;
  end if;

  select * into v_key
  from public.network_root_key_registry
  where id=p_key_registry_id
  for update;
  if not found then raise exception 'key registry % does not exist', p_key_registry_id; end if;
  if v_key.status <> 'active' then raise exception 'key registry % is not active', p_key_registry_id; end if;

  if exists (
    select 1 from public.network_signing_workflow_signatures
    where workflow_id=p_workflow_id and signer_user_id=p_signer_user_id
  ) then
    raise exception 'signer % has already signed workflow %', p_signer_user_id, p_workflow_id;
  end if;

  insert into public.network_signing_workflow_signatures(
    workflow_id, signer_user_id, key_registry_id, signature_digest, signed_payload_digest
  ) values (
    p_workflow_id, p_signer_user_id, p_key_registry_id, btrim(p_signature_digest), btrim(p_signed_payload_digest)
  );

  select count(*)::integer into v_count
  from public.network_signing_workflow_signatures
  where workflow_id=p_workflow_id;

  update public.network_signing_workflows
  set collected_signatures=v_count,
      status=case when v_count >= required_signatures then 'approved' else 'pending' end,
      executed_at=case when v_count >= required_signatures then clock_timestamp() else executed_at end
  where id=p_workflow_id;

  return query select status, collected_signatures, required_signatures
  from public.network_signing_workflows where id=p_workflow_id;
end;
$$;

revoke all on function public.v33_record_signature(uuid,uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function public.v33_record_signature(uuid,uuid,uuid,text,text) to service_role;

create or replace function public.v33_protect_signing_signature()
returns trigger
language plpgsql
set search_path = pg_catalog, public, extensions, pg_temp
as $$
begin
  if tg_op <> 'INSERT' then
    raise exception 'signing workflow signatures are append-only';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_v33_signing_signature_immutable on public.network_signing_workflow_signatures;
create trigger trg_v33_signing_signature_immutable
before update or delete on public.network_signing_workflow_signatures
for each row execute function public.v33_protect_signing_signature();

revoke all on function public.v33_protect_signing_signature() from public, anon, authenticated;
grant execute on function public.v33_protect_signing_signature() to service_role;
