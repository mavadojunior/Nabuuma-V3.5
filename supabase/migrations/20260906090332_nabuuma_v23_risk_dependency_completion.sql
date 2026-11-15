create table if not exists public.v23_shipment_risk_snapshots (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  shipment_id uuid not null references public.v22_logistics_shipments(id) on delete cascade,
  risk_score numeric(8,4) not null check(risk_score between 0 and 100),
  risk_level text not null check(risk_level in ('low','medium','high','critical')),
  factors jsonb not null default '{}'::jsonb,
  calculated_at timestamptz not null default now(),
  unique(business_id,shipment_id)
);
create table if not exists public.v23_recovery_recommendations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  shipment_id uuid references public.v22_logistics_shipments(id) on delete cascade,
  supplier_id uuid references public.suppliers(id) on delete restrict,
  recommendation_type text not null,
  priority text not null check(priority in ('low','medium','high','critical')),
  rationale jsonb not null default '{}'::jsonb,
  status text not null default 'open' check(status in ('open','accepted','rejected','resolved')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create table if not exists public.v23_supplier_risk_snapshots (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete cascade,
  risk_score numeric(8,4) not null check(risk_score between 0 and 100),
  risk_level text not null check(risk_level in ('low','medium','high','critical')),
  factors jsonb not null default '{}'::jsonb,
  calculated_at timestamptz not null default now(),
  unique(business_id,supplier_id)
);
create index if not exists idx_v23_supplier_risk_business on public.v23_supplier_risk_snapshots(business_id,risk_score desc);
create index if not exists idx_v23_shipment_risk_business on public.v23_shipment_risk_snapshots(business_id,risk_score desc);
alter table public.v23_supplier_risk_snapshots enable row level security;
alter table public.v23_shipment_risk_snapshots enable row level security;
alter table public.v23_recovery_recommendations enable row level security;
drop policy if exists v23_supplier_risk_select on public.v23_supplier_risk_snapshots;
create policy v23_supplier_risk_select on public.v23_supplier_risk_snapshots for select using(is_member(business_id));
drop policy if exists v23_shipment_risk_select on public.v23_shipment_risk_snapshots;
create policy v23_shipment_risk_select on public.v23_shipment_risk_snapshots for select using(is_member(business_id));
drop policy if exists v23_recovery_select on public.v23_recovery_recommendations;
create policy v23_recovery_select on public.v23_recovery_recommendations for select using(is_member(business_id));
revoke insert,update,delete on public.v23_supplier_risk_snapshots from authenticated;
revoke insert,update,delete on public.v23_shipment_risk_snapshots from authenticated;
revoke insert,update,delete on public.v23_recovery_recommendations from authenticated;
create or replace function public.refresh_v23_supplier_risk(p_business_id uuid,p_window_days integer default 365)
returns jsonb language plpgsql security definer set search_path=public as $$
declare n integer;
begin
  if not has_role(p_business_id,ARRAY['owner','manager']::member_role[]) then raise exception 'Manager authorization required'; end if;
  if p_window_days not between 1 and 3650 then raise exception 'Window must be between 1 and 3650 days'; end if;
  delete from public.v23_supplier_risk_snapshots where business_id=p_business_id;
  insert into public.v23_supplier_risk_snapshots(business_id,supplier_id,risk_score,risk_level,factors)
  select s.business_id,s.id,least(100,greatest(0,coalesce(100-sm.reliability_score,0))),
         case when coalesce(100-sm.reliability_score,0)>=75 then 'critical' when coalesce(100-sm.reliability_score,0)>=50 then 'high' when coalesce(100-sm.reliability_score,0)>=25 then 'medium' else 'low' end,
         jsonb_build_object('reliability_score',sm.reliability_score,'window_days',p_window_days)
  from public.suppliers s
  left join public.supplier_execution_metrics sm on sm.business_id=s.business_id and sm.supplier_id=s.id
  where s.business_id=p_business_id;
  get diagnostics n=row_count;
  return jsonb_build_object('business_id',p_business_id,'supplier_snapshots',n);
end $$;
grant execute on function public.refresh_v23_supplier_risk(uuid,integer) to authenticated;
create or replace function public.refresh_v23_shipment_risk(p_business_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare n integer;
begin
  if not has_role(p_business_id,ARRAY['owner','manager']::member_role[]) then raise exception 'Manager authorization required'; end if;
  delete from public.v23_shipment_risk_snapshots where business_id=p_business_id;
  insert into public.v23_shipment_risk_snapshots(business_id,shipment_id,risk_score,risk_level,factors)
  select sh.business_id,sh.id,
    case when sh.status in ('exception','cancelled') then 100 when sh.eta_at is not null and sh.eta_at<now() and sh.status<>'delivered' then 75 when sh.status in ('planned','confirmed') then 25 else 10 end,
    case when sh.status in ('exception','cancelled') then 'critical' when sh.eta_at is not null and sh.eta_at<now() and sh.status<>'delivered' then 'high' when sh.status in ('planned','confirmed') then 'medium' else 'low' end,
    jsonb_build_object('status',sh.status,'eta_at',sh.eta_at)
  from public.v22_logistics_shipments sh where sh.business_id=p_business_id;
  get diagnostics n=row_count;
  return jsonb_build_object('business_id',p_business_id,'shipment_snapshots',n);
end $$;
grant execute on function public.refresh_v23_shipment_risk(uuid) to authenticated;