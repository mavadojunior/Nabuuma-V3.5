begin;
create table if not exists public.network_tenant_keys (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id), key_id text not null, algorithm text not null default 'Ed25519', public_key text not null, status text not null default 'active' check(status in('active','retired','revoked')), created_at timestamptz not null default now(), retired_at timestamptz, unique(business_id,key_id)
);
create table if not exists public.network_key_rotation_logs (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id), old_key_id text, new_key_id text not null, reason text not null, actor_user_id uuid references auth.users(id), created_at timestamptz not null default now()
);
create table if not exists public.network_organization_verifications (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.network_organizations(id) on delete cascade, verification_type text not null check(verification_type in('identity','tax','bank','address','legal')), status text not null default 'pending' check(status in('pending','verified','rejected','expired')), evidence jsonb not null default '{}'::jsonb, verified_at timestamptz, expires_at timestamptz, verified_by uuid references auth.users(id), created_at timestamptz not null default now()
);
create table if not exists public.network_contract_negotiations (
 id uuid primary key default gen_random_uuid(), contract_id uuid not null references public.network_contracts(id) on delete cascade, version_no integer not null check(version_no>0), status text not null default 'proposed' check(status in('proposed','countered','accepted','rejected','withdrawn')), terms jsonb not null default '{}'::jsonb, proposed_by uuid references auth.users(id), proposed_at timestamptz not null default now(), accepted_at timestamptz, unique(contract_id,version_no)
);
create table if not exists public.network_contract_negotiation_lines (
 id uuid primary key default gen_random_uuid(), negotiation_id uuid not null references public.network_contract_negotiations(id) on delete cascade, contract_line_id uuid references public.network_contract_lines(id), unit text not null, quantity numeric(24,8) check(quantity is null or quantity>0), unit_price_minor bigint not null default 0 check(unit_price_minor>=0), terms jsonb not null default '{}'::jsonb
);
create table if not exists public.network_contract_signatures (
 id uuid primary key default gen_random_uuid(), contract_id uuid not null references public.network_contracts(id) on delete cascade, business_id uuid not null references public.businesses(id), key_id text not null, signature text not null, signed_payload_hash text not null, signed_at timestamptz not null default now(), status text not null default 'valid' check(status in('valid','revoked'))
);
create table if not exists public.network_dispatched_receipts (
 id uuid primary key default gen_random_uuid(), dispatch_id uuid not null references public.network_order_dispatches(id) on delete cascade, buyer_business_id uuid not null references public.businesses(id), seller_business_id uuid not null references public.businesses(id), receipt_status text not null default 'committed' check(receipt_status in('committed','superseded')), received_quantity numeric(24,8) not null check(received_quantity>=0), unit text not null, evidence jsonb not null default '{}'::jsonb, received_by uuid references auth.users(id), received_at timestamptz not null default now()
);
create table if not exists public.network_dispatches_disputes (
 id uuid primary key default gen_random_uuid(), dispatch_id uuid not null references public.network_order_dispatches(id) on delete cascade, opened_by uuid references auth.users(id), reason text not null, disputed_quantity numeric(24,8), status text not null default 'open' check(status in('open','under_review','accepted','rejected','partially_adjusted','closed')), resolution jsonb not null default '{}'::jsonb, created_at timestamptz not null default now(), resolved_at timestamptz
);
create index if not exists idx_network_receipts_dispatch on public.network_dispatched_receipts(dispatch_id,receipt_status);
create index if not exists idx_network_disputes_dispatch on public.network_dispatches_disputes(dispatch_id,status);
alter table public.network_tenant_keys enable row level security;
alter table public.network_key_rotation_logs enable row level security;
alter table public.network_organization_verifications enable row level security;
alter table public.network_contract_negotiations enable row level security;
alter table public.network_contract_negotiation_lines enable row level security;
alter table public.network_contract_signatures enable row level security;
alter table public.network_dispatched_receipts enable row level security;
alter table public.network_dispatches_disputes enable row level security;
create policy network_tenant_keys_member_select on public.network_tenant_keys for select to authenticated using(exists(select 1 from public.business_members bm where bm.business_id=network_tenant_keys.business_id and bm.user_id=auth.uid()));
create policy network_key_rotation_member_select on public.network_key_rotation_logs for select to authenticated using(exists(select 1 from public.business_members bm where bm.business_id=network_key_rotation_logs.business_id and bm.user_id=auth.uid()));
create policy network_verification_member_select on public.network_organization_verifications for select to authenticated using(exists(select 1 from public.network_organizations o join public.business_members bm on bm.business_id=o.business_id where o.id=network_organization_verifications.organization_id and bm.user_id=auth.uid()));
create policy network_negotiation_member_select on public.network_contract_negotiations for select to authenticated using(exists(select 1 from public.network_contracts c join public.business_members bm on bm.business_id=c.buyer_business_id or bm.business_id=c.seller_business_id where c.id=network_contract_negotiations.contract_id and bm.user_id=auth.uid()));
create policy network_negotiation_line_member_select on public.network_contract_negotiation_lines for select to authenticated using(exists(select 1 from public.network_contract_negotiations n join public.network_contracts c on c.id=n.contract_id join public.business_members bm on bm.business_id=c.buyer_business_id or bm.business_id=c.seller_business_id where n.id=network_contract_negotiation_lines.negotiation_id and bm.user_id=auth.uid()));
create policy network_signature_member_select on public.network_contract_signatures for select to authenticated using(exists(select 1 from public.business_members bm where bm.business_id=network_contract_signatures.business_id and bm.user_id=auth.uid()));
create policy network_receipt_member_select on public.network_dispatched_receipts for select to authenticated using(exists(select 1 from public.business_members bm where (bm.business_id=network_dispatched_receipts.buyer_business_id or bm.business_id=network_dispatched_receipts.seller_business_id) and bm.user_id=auth.uid()));
create policy network_dispute_member_select on public.network_dispatches_disputes for select to authenticated using(exists(select 1 from public.network_order_dispatches d join public.business_members bm on bm.business_id=d.buyer_business_id or bm.business_id=d.seller_business_id where d.id=network_dispatches_disputes.dispatch_id and bm.user_id=auth.uid()));
revoke insert,update,delete on public.network_tenant_keys,public.network_key_rotation_logs,public.network_organization_verifications,public.network_contract_negotiations,public.network_contract_negotiation_lines,public.network_contract_signatures,public.network_dispatched_receipts,public.network_dispatches_disputes from anon,authenticated;
grant execute on function public.nos_hash_payload(jsonb,text) to authenticated,service_role;
commit;