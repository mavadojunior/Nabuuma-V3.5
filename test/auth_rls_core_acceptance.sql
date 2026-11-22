\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
VALUES
 ('30000000-0000-0000-0000-000000000001','authenticated','authenticated','owner-a@example.invalid','',now(),'{}','{}',now(),now()),
 ('30000000-0000-0000-0000-000000000002','authenticated','authenticated','owner-b@example.invalid','',now(),'{}','{}',now(),now());
INSERT INTO public.businesses (id,name,currency,timezone) VALUES
 ('40000000-0000-0000-0000-000000000001','RLS Tenant A','AED','Asia/Dubai'),
 ('40000000-0000-0000-0000-000000000002','RLS Tenant B','AED','Asia/Dubai');
INSERT INTO public.business_members (business_id,user_id,role) VALUES
 ('40000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','owner'),
 ('40000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000002','owner');
INSERT INTO public.products (id,business_id,code,name) VALUES
 ('50000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','RLS-A-1','Tenant A product'),
 ('50000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000002','RLS-B-1','Tenant B product');

-- anon: all four operations must be rejected at the ACL boundary.
SET LOCAL ROLE anon;
DO $anon_matrix$
BEGIN
  BEGIN PERFORM 1 FROM public.products; RAISE EXCEPTION 'anon SELECT unexpectedly succeeded'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN INSERT INTO public.products(business_id,code,name) VALUES ('40000000-0000-0000-0000-000000000001','ANON','anon'); RAISE EXCEPTION 'anon INSERT unexpectedly succeeded'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN UPDATE public.products SET name='anon' WHERE id='50000000-0000-0000-0000-000000000001'; RAISE EXCEPTION 'anon UPDATE unexpectedly succeeded'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN DELETE FROM public.products WHERE id='50000000-0000-0000-0000-000000000001'; RAISE EXCEPTION 'anon DELETE unexpectedly succeeded'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END
$anon_matrix$;
RESET ROLE;

-- Authenticated user from tenant B cannot see, create into, update or delete tenant A data.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='30000000-0000-0000-0000-000000000002';
SET LOCAL request.jwt.claims='{"sub":"30000000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $cross_tenant_matrix$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM public.products WHERE id='50000000-0000-0000-0000-000000000001';
  IF n<>0 THEN RAISE EXCEPTION 'cross-tenant SELECT leaked % rows',n; END IF;
  BEGIN INSERT INTO public.products(business_id,code,name) VALUES ('40000000-0000-0000-0000-000000000001','CROSS','cross'); RAISE EXCEPTION 'cross-tenant INSERT unexpectedly succeeded'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  UPDATE public.products SET name='cross-update' WHERE id='50000000-0000-0000-0000-000000000001';
  GET DIAGNOSTICS n=ROW_COUNT;
  IF n<>0 THEN RAISE EXCEPTION 'cross-tenant UPDATE changed % rows',n; END IF;
  DELETE FROM public.products WHERE id='50000000-0000-0000-0000-000000000001';
  GET DIAGNOSTICS n=ROW_COUNT;
  IF n<>0 THEN RAISE EXCEPTION 'cross-tenant DELETE removed % rows',n; END IF;
END
$cross_tenant_matrix$;
RESET ROLE;

-- Authorized owner has full tenant-scoped CRUD.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='30000000-0000-0000-0000-000000000001';
SET LOCAL request.jwt.claims='{"sub":"30000000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $owner_matrix$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM public.products WHERE id='50000000-0000-0000-0000-000000000001';
  IF n<>1 THEN RAISE EXCEPTION 'owner cannot SELECT own row'; END IF;
  INSERT INTO public.products(business_id,code,name) VALUES ('40000000-0000-0000-0000-000000000001','OWNER-CRUD','owner-created');
  UPDATE public.products SET name='owner-updated' WHERE code='OWNER-CRUD';
  GET DIAGNOSTICS n=ROW_COUNT;
  IF n<>1 THEN RAISE EXCEPTION 'owner UPDATE affected % rows',n; END IF;
  DELETE FROM public.products WHERE code='OWNER-CRUD';
  GET DIAGNOSTICS n=ROW_COUNT;
  IF n<>1 THEN RAISE EXCEPTION 'owner DELETE affected % rows',n; END IF;
END
$owner_matrix$;
RESET ROLE;

-- service_role bypasses RLS across tenants and retains table-level CRUD.
SET LOCAL ROLE service_role;
DO $service_matrix$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM public.products WHERE id IN ('50000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000002');
  IF n<>2 THEN RAISE EXCEPTION 'service_role did not bypass tenant RLS'; END IF;
  INSERT INTO public.products(business_id,code,name) VALUES ('40000000-0000-0000-0000-000000000002','SERVICE-CRUD','service-created');
  UPDATE public.products SET name='service-updated' WHERE code='SERVICE-CRUD';
  GET DIAGNOSTICS n=ROW_COUNT;
  IF n<>1 THEN RAISE EXCEPTION 'service_role UPDATE affected % rows',n; END IF;
  DELETE FROM public.products WHERE code='SERVICE-CRUD';
  GET DIAGNOSTICS n=ROW_COUNT;
  IF n<>1 THEN RAISE EXCEPTION 'service_role DELETE affected % rows',n; END IF;
END
$service_matrix$;
RESET ROLE;

ROLLBACK;
SELECT 'PASS: anon, cross-tenant, owner and service_role CRUD matrix for products' AS result;
