create table if not exists public.network_break_glass_authorizations (
 id uuid primary key default gen_random_uuid(),
 workflow_id uuid not null references public.network_signing_workflows(id),
 authorization_digest text not null unique,
 scope jsonb not null,
 authorized_by uuid not null,
 second_authorizer uuid,
 issued_at timestamptz not null default now(),
 expires_at timestamptz not null,
 consumed_at timestamptz,
 revoked_at timestamptz,
 constraint bg_auth_expiry_chk check (expires_at > issued_at),
 constraint bg_auth_distinct_chk check (second_authorizer is null or second_authorizer <> authorized_by),
 constraint bg_auth_digest_chk check (length(authorization_digest) between 64 and 128)
);

create index if not exists network_break_glass_auth_workflow_idx on public.network_break_glass_authorizations(workflow_id);
create index if not exists network_break_glass_auth_active_idx on public.network_break_glass_authorizations(expires_at) where consumed_at is null and revoked_at is null;

alter table public.network_break_glass_authorizations enable row level security;
revoke all on public.network_break_glass_authorizations from anon, authenticated;
grant select, insert, update on public.network_break_glass_authorizations to service_role;

create or replace function public.v34_consume_break_glass_authorization(p_authorization_id uuid, p_workflow_id uuid, p_scope jsonb)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare v_scope jsonb; v_expires timestamptz; v_revoked timestamptz; v_consumed timestamptz;
begin
 select scope, expires_at, revoked_at, consumed_at into v_scope,v_expires,v_revoked,v_consumed
 from public.network_break_glass_authorizations where id=p_authorization_id and workflow_id=p_workflow_id for update;
 if not found then raise exception 'break-glass authorization not found'; end if;
 if v_revoked is not null then raise exception 'break-glass authorization revoked'; end if;
 if v_consumed is not null then raise exception 'break-glass authorization already consumed'; end if;
 if v_expires <= clock_timestamp() then raise exception 'break-glass authorization expired'; end if;
 if v_scope <> p_scope then raise exception 'break-glass scope mismatch'; end if;
 update public.network_break_glass_authorizations set consumed_at=clock_timestamp() where id=p_authorization_id;
 return true;
end $$;

revoke all on function public.v34_consume_break_glass_authorization(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.v34_consume_break_glass_authorization(uuid,uuid,jsonb) to service_role;

create or replace function public.v34_protect_break_glass_authorization()
returns trigger language plpgsql set search_path=pg_catalog,public,extensions,pg_temp as $$
begin
 if tg_op='DELETE' then raise exception 'break-glass authorization is immutable'; end if;
 if tg_op='UPDATE' and (old.workflow_id,old.authorization_digest,old.scope,old.authorized_by,old.second_authorizer,old.issued_at) is distinct from (new.workflow_id,new.authorization_digest,new.scope,new.authorized_by,new.second_authorizer,new.issued_at) then raise exception 'break-glass authorization identity is immutable'; end if;
 return new;
end $$;
drop trigger if exists trg_v34_protect_break_glass_authorization on public.network_break_glass_authorizations;
create trigger trg_v34_protect_break_glass_authorization before update or delete on public.network_break_glass_authorizations for each row execute function public.v34_protect_break_glass_authorization();
revoke all on function public.v34_protect_break_glass_authorization() from public,anon,authenticated;
grant execute on function public.v34_protect_break_glass_authorization() to service_role;