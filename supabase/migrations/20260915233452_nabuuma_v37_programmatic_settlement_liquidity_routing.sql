create table if not exists public.network_liquidity_sources (
  liquidity_source_id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  financial_account_id uuid not null references public.financial_accounts(id) on delete restrict,
  currency text not null,
  capacity_minor bigint not null check (capacity_minor >= 0),
  reserved_minor bigint not null default 0 check (reserved_minor >= 0 and reserved_minor <= capacity_minor),
  priority smallint not null default 100 check (priority between 0 and 32767),
  status text not null default 'active' check (status in ('active','paused','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, financial_account_id),
  foreign key (currency) references public.gcc_supported_currencies(currency_code)
);

create table if not exists public.network_settlement_routes (
  route_id uuid primary key default gen_random_uuid(),
  settlement_batch_id uuid not null unique references public.settlement_batches(id) on delete restrict,
  buyer_business_id uuid not null,
  seller_business_id uuid not null,
  currency text not null references public.gcc_supported_currencies(currency_code),
  principal_minor bigint not null check (principal_minor > 0),
  fee_minor bigint not null default 0 check (fee_minor >= 0),
  state text not null default 'planned' check (state in ('planned','reserved','authorized','executing','completed','released','failed','cancelled')),
  routing_policy text not null default 'priority_capacity',
  route_hash text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  authorized_at timestamptz,
  completed_at timestamptz,
  unique (route_id, state)
);

create table if not exists public.network_settlement_route_legs (
  route_leg_id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.network_settlement_routes(route_id) on delete restrict,
  sequence_no integer not null check (sequence_no > 0),
  liquidity_source_id uuid not null references public.network_liquidity_sources(liquidity_source_id) on delete restrict,
  amount_minor bigint not null check (amount_minor > 0),
  fee_minor bigint not null default 0 check (fee_minor >= 0),
  currency text not null references public.gcc_supported_currencies(currency_code),
  created_at timestamptz not null default now(),
  unique (route_id, sequence_no),
  unique (route_id, liquidity_source_id)
);

create table if not exists public.network_liquidity_reservations (
  reservation_id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.network_settlement_routes(route_id) on delete restrict,
  liquidity_source_id uuid not null references public.network_liquidity_sources(liquidity_source_id) on delete restrict,
  amount_minor bigint not null check (amount_minor > 0),
  state text not null default 'reserved' check (state in ('reserved','consumed','released','expired')),
  created_at timestamptz not null default now(),
  consumed_at timestamptz,
  released_at timestamptz,
  unique (route_id, liquidity_source_id)
);

create table if not exists public.network_settlement_routing_events (
  event_id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.network_settlement_routes(route_id) on delete restrict,
  event_type text not null check (event_type in ('route_planned','liquidity_reserved','route_authorized','execution_started','execution_completed','route_released','route_failed','route_cancelled')),
  payload jsonb not null default '{}'::jsonb,
  previous_hash text,
  event_hash text not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (route_id,event_hash)
);

alter table public.network_liquidity_sources enable row level security;
alter table public.network_settlement_routes enable row level security;
alter table public.network_settlement_route_legs enable row level security;
alter table public.network_liquidity_reservations enable row level security;
alter table public.network_settlement_routing_events enable row level security;

create policy network_liquidity_sources_member_select on public.network_liquidity_sources for select to authenticated using (exists (select 1 from public.business_members bm where bm.business_id=network_liquidity_sources.business_id and bm.user_id=auth.uid()));
create policy network_settlement_routes_member_select on public.network_settlement_routes for select to authenticated using (exists (select 1 from public.business_members bm where bm.business_id=network_settlement_routes.buyer_business_id and bm.user_id=auth.uid()) or exists (select 1 from public.business_members bm where bm.business_id=network_settlement_routes.seller_business_id and bm.user_id=auth.uid()));
create policy network_settlement_route_legs_member_select on public.network_settlement_route_legs for select to authenticated using (exists (select 1 from public.network_settlement_routes r join public.business_members bm on (bm.business_id=r.buyer_business_id or bm.business_id=r.seller_business_id) where r.route_id=network_settlement_route_legs.route_id and bm.user_id=auth.uid()));
create policy network_liquidity_reservations_member_select on public.network_liquidity_reservations for select to authenticated using (exists (select 1 from public.network_settlement_routes r join public.business_members bm on (bm.business_id=r.buyer_business_id or bm.business_id=r.seller_business_id) where r.route_id=network_liquidity_reservations.route_id and bm.user_id=auth.uid()));
create policy network_settlement_routing_events_member_select on public.network_settlement_routing_events for select to authenticated using (exists (select 1 from public.network_settlement_routes r join public.business_members bm on (bm.business_id=r.buyer_business_id or bm.business_id=r.seller_business_id) where r.route_id=network_settlement_routing_events.route_id and bm.user_id=auth.uid()));

revoke all on public.network_liquidity_sources,public.network_settlement_routes,public.network_settlement_route_legs,public.network_liquidity_reservations,public.network_settlement_routing_events from anon,authenticated;
grant select on public.network_liquidity_sources,public.network_settlement_routes,public.network_settlement_route_legs,public.network_liquidity_reservations,public.network_settlement_routing_events to authenticated;

create index if not exists network_liquidity_sources_capacity_idx on public.network_liquidity_sources(business_id,currency,status,priority);
create index if not exists network_settlement_routes_batch_idx on public.network_settlement_routes(settlement_batch_id);
create index if not exists network_settlement_routes_parties_idx on public.network_settlement_routes(buyer_business_id,seller_business_id);
create index if not exists network_settlement_route_legs_route_idx on public.network_settlement_route_legs(route_id,sequence_no);
create index if not exists network_liquidity_reservations_source_idx on public.network_liquidity_reservations(liquidity_source_id,state);
create index if not exists network_settlement_routing_events_route_idx on public.network_settlement_routing_events(route_id,created_at);

create or replace function public.network_register_liquidity_source(p_business_id uuid,p_financial_account_id uuid,p_capacity_minor bigint,p_priority smallint default 100) returns uuid language plpgsql security definer set search_path=pg_catalog,public,extensions,pg_temp as $f$
declare v_id uuid; v_currency text; v_account_business uuid;
begin
 if p_business_id is null or p_financial_account_id is null or p_capacity_minor < 0 then raise exception 'invalid liquidity source'; end if;
 select currency,business_id into v_currency,v_account_business from public.financial_accounts where id=p_financial_account_id and active=true for update;
 if v_currency is null or v_account_business is distinct from p_business_id then raise exception 'financial account is not owned by business'; end if;
 perform pg_advisory_xact_lock(pg_catalog.hashtextextended('liquidity:'||p_business_id::text,0));
 insert into public.network_liquidity_sources(business_id,financial_account_id,currency,capacity_minor,priority) values(p_business_id,p_financial_account_id,v_currency,p_capacity_minor,p_priority)
 on conflict (business_id,financial_account_id) do update set capacity_minor=excluded.capacity_minor,priority=excluded.priority,status='active',updated_at=now()
 returning liquidity_source_id into v_id;
 return v_id;
end $f$;

create or replace function public.network_compile_settlement_route(p_settlement_batch_id uuid) returns uuid language plpgsql security definer set search_path=pg_catalog,public,extensions,pg_temp as $f$
declare v_route uuid; v_buyer uuid; v_seller uuid; v_currency text; v_amount bigint; v_remaining bigint; v_source record; v_seq integer:=0; v_take bigint; v_hash text;
begin
 select buyer_business_id,seller_business_id,currency,total_minor into v_buyer,v_seller,v_currency,v_amount from public.settlement_batches where id=p_settlement_batch_id for update;
 if v_buyer is null or v_seller is null or v_amount is null or v_amount <= 0 then raise exception 'invalid settlement batch'; end if;
 if v_buyer=v_seller then raise exception 'buyer and seller must differ'; end if;
 perform pg_advisory_xact_lock(pg_catalog.hashtextextended('route:'||p_settlement_batch_id::text,0));
 select route_id into v_route from public.network_settlement_routes where settlement_batch_id=p_settlement_batch_id;
 if v_route is not null then return v_route; end if;
 insert into public.network_settlement_routes(settlement_batch_id,buyer_business_id,seller_business_id,currency,principal_minor) values(p_settlement_batch_id,v_buyer,v_seller,v_currency,v_amount) returning route_id into v_route;
 v_remaining:=v_amount;
 for v_source in select liquidity_source_id,capacity_minor,reserved_minor,priority from public.network_liquidity_sources where business_id=v_buyer and currency=v_currency and status='active' and capacity_minor>reserved_minor order by priority asc,liquidity_source_id for update loop
   exit when v_remaining=0;
   v_take:=least(v_remaining,v_source.capacity_minor-v_source.reserved_minor);
   if v_take>0 then
     v_seq:=v_seq+1;
     update public.network_liquidity_sources set reserved_minor=reserved_minor+v_take,updated_at=now() where liquidity_source_id=v_source.liquidity_source_id;
     insert into public.network_settlement_route_legs(route_id,sequence_no,liquidity_source_id,amount_minor,fee_minor,currency) values(v_route,v_seq,v_source.liquidity_source_id,v_take,0,v_currency);
     insert into public.network_liquidity_reservations(route_id,liquidity_source_id,amount_minor) values(v_route,v_source.liquidity_source_id,v_take);
     v_remaining:=v_remaining-v_take;
   end if;
 end loop;
 if v_remaining<>0 then raise exception 'insufficient liquidity capacity'; end if;
 v_hash:=encode(extensions.digest(convert_to(v_route::text||':'||p_settlement_batch_id::text||':'||v_amount::text||':'||v_currency,'UTF8'),'sha256'),'hex');
 update public.network_settlement_routes set state='reserved',route_hash=v_hash,updated_at=now() where route_id=v_route;
 insert into public.network_settlement_routing_events(route_id,event_type,payload,event_hash,created_by) values(v_route,'route_planned',jsonb_build_object('principal_minor',v_amount,'currency',v_currency),'route:'||v_hash,auth.uid());
 insert into public.network_settlement_routing_events(route_id,event_type,payload,previous_hash,event_hash,created_by) values(v_route,'liquidity_reserved',jsonb_build_object('legs',v_seq),'route:'||v_hash,'reserve:'||v_hash,auth.uid());
 return v_route;
end $f$;

create or replace function public.network_authorize_settlement_route(p_route_id uuid) returns void language plpgsql security definer set search_path=pg_catalog,public,extensions,pg_temp as $f$
declare v_state text; v_batch uuid; v_previous text; v_hash text;
begin
 select state,settlement_batch_id into v_state,v_batch from public.network_settlement_routes where route_id=p_route_id for update;
 if v_state is null then raise exception 'route not found'; end if;
 if v_state<>'reserved' then raise exception 'route must be reserved before authorization'; end if;
 select event_hash into v_previous from public.network_settlement_routing_events where route_id=p_route_id order by created_at desc,event_id desc limit 1;
 v_hash:=encode(extensions.digest(convert_to(p_route_id::text||':route_authorized:'||coalesce(v_previous,''),'UTF8'),'sha256'),'hex');
 update public.network_settlement_routes set state='authorized',authorized_at=now(),updated_at=now() where route_id=p_route_id;
 insert into public.network_settlement_routing_events(route_id,event_type,previous_hash,event_hash,created_by) values(p_route_id,'route_authorized',v_previous,v_hash,auth.uid());
end $f$;

create or replace function public.network_release_settlement_route(p_route_id uuid,p_reason text) returns void language plpgsql security definer set search_path=pg_catalog,public,extensions,pg_temp as $f$
declare v_state text; v_previous text; v_hash text;
begin
 select state into v_state from public.network_settlement_routes where route_id=p_route_id for update;
 if v_state is null then raise exception 'route not found'; end if;
 if v_state not in ('reserved','failed','cancelled') then raise exception 'route cannot be released from current state'; end if;
 perform pg_advisory_xact_lock(pg_catalog.hashtextextended('route:'||p_route_id::text,0));
 update public.network_liquidity_sources s set reserved_minor=s.reserved_minor-r.amount_minor,updated_at=now() from public.network_liquidity_reservations r where r.route_id=p_route_id and r.liquidity_source_id=s.liquidity_source_id and r.state='reserved';
 update public.network_liquidity_reservations set state='released',released_at=now() where route_id=p_route_id and state='reserved';
 select event_hash into v_previous from public.network_settlement_routing_events where route_id=p_route_id order by created_at desc,event_id desc limit 1;
 v_hash:=encode(extensions.digest(convert_to(p_route_id::text||':route_released:'||coalesce(p_reason,'')||':'||coalesce(v_previous,''),'UTF8'),'sha256'),'hex');
 update public.network_settlement_routes set state='released',updated_at=now() where route_id=p_route_id;
 insert into public.network_settlement_routing_events(route_id,event_type,payload,previous_hash,event_hash,created_by) values(p_route_id,'route_released',jsonb_build_object('reason',coalesce(p_reason,'')),v_previous,v_hash,auth.uid());
end $f$;

revoke execute on function public.network_register_liquidity_source(uuid,uuid,bigint,smallint) from public,anon,authenticated;
revoke execute on function public.network_compile_settlement_route(uuid) from public,anon,authenticated;
revoke execute on function public.network_authorize_settlement_route(uuid) from public,anon,authenticated;
revoke execute on function public.network_release_settlement_route(uuid,text) from public,anon,authenticated;
grant execute on function public.network_register_liquidity_source(uuid,uuid,bigint,smallint) to service_role;
grant execute on function public.network_compile_settlement_route(uuid) to service_role;
grant execute on function public.network_authorize_settlement_route(uuid) to service_role;
grant execute on function public.network_release_settlement_route(uuid,text) to service_role;

create or replace function public.network_settlement_routing_events_immutable_guard() returns trigger language plpgsql set search_path=pg_catalog,public,extensions,pg_temp as $f$ begin raise exception 'settlement routing events are append-only'; end $f$;
drop trigger if exists network_settlement_routing_events_immutable_guard on public.network_settlement_routing_events;
create trigger network_settlement_routing_events_immutable_guard before update or delete on public.network_settlement_routing_events for each row execute function public.network_settlement_routing_events_immutable_guard();
revoke insert,update,delete on public.network_settlement_routing_events from service_role;
grant select on public.network_settlement_routing_events to service_role;
revoke insert,update,delete on public.network_settlement_routes,public.network_settlement_route_legs,public.network_liquidity_reservations,public.network_liquidity_sources from service_role;
grant select on public.network_settlement_routes,public.network_settlement_route_legs,public.network_liquidity_reservations,public.network_liquidity_sources to service_role;
