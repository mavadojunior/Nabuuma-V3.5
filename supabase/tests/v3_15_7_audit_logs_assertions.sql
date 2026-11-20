\set ON_ERROR_STOP on

DO $test$
DECLARE
    v_privilege text;
    v_relation oid := 'public.audit_logs'::regclass;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_class
         WHERE oid = v_relation
           AND relrowsecurity
           AND NOT relforcerowsecurity
    ) THEN
        RAISE EXCEPTION 'RLS must be enabled but not forced on audit_logs';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_policies
         WHERE schemaname='public'
           AND tablename='audit_logs'
           AND policyname='reject_all_public_access'
    ) THEN
        RAISE EXCEPTION 'Legacy permissive false policy remains';
    END IF;

    IF (
        SELECT count(*) FROM pg_catalog.pg_policies
         WHERE schemaname='public'
           AND tablename='audit_logs'
           AND policyname IN (
             'v3157_audit_logs_select_guard',
             'v3157_audit_logs_insert_guard',
             'v3157_audit_logs_update_deny',
             'v3157_audit_logs_delete_deny'
           )
           AND permissive='RESTRICTIVE'
           AND 'public'=ANY(roles)
    ) <> 4 THEN
        RAISE EXCEPTION 'Expected four PUBLIC restrictive guards';
    END IF;

    IF NOT pg_catalog.has_table_privilege('authenticated',v_relation,'SELECT')
       OR NOT pg_catalog.has_table_privilege('authenticated',v_relation,'INSERT') THEN
        RAISE EXCEPTION 'authenticated must retain SELECT and INSERT';
    END IF;

    IF NOT (SELECT rolbypassrls FROM pg_catalog.pg_roles WHERE rolname='service_role') THEN
        RAISE EXCEPTION 'service_role must retain BYPASSRLS';
    END IF;

    FOREACH v_privilege IN ARRAY ARRAY[
      'UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'
    ] LOOP
      IF pg_catalog.has_table_privilege('authenticated',v_relation,v_privilege) THEN
        RAISE EXCEPTION 'authenticated retains forbidden %',v_privilege;
      END IF;
    END LOOP;

    FOREACH v_privilege IN ARRAY ARRAY[
      'SELECT','INSERT','UPDATE','DELETE','TRUNCATE',
      'REFERENCES','TRIGGER','MAINTAIN'
    ] LOOP
      IF pg_catalog.has_table_privilege('anon',v_relation,v_privilege) THEN
        RAISE EXCEPTION 'anon retains %',v_privilege;
      END IF;
      IF NOT pg_catalog.has_table_privilege('service_role',v_relation,v_privilege) THEN
        RAISE EXCEPTION 'service_role lost %',v_privilege;
      END IF;
    END LOOP;

    IF pg_catalog.has_any_column_privilege('anon',v_relation,'SELECT')
       OR pg_catalog.has_any_column_privilege('anon',v_relation,'INSERT')
       OR pg_catalog.has_any_column_privilege('anon',v_relation,'UPDATE')
       OR pg_catalog.has_any_column_privilege('anon',v_relation,'REFERENCES')
       OR pg_catalog.has_any_column_privilege('authenticated',v_relation,'UPDATE')
       OR pg_catalog.has_any_column_privilege('authenticated',v_relation,'REFERENCES') THEN
      RAISE EXCEPTION 'Forbidden column-level privilege remains';
    END IF;
END
$test$;

-- A second tenant must not read or write the first tenant's audit records.
INSERT INTO public.business_members (business_id,user_id)
VALUES (
  '10000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-000000000002'
);

SET ROLE authenticated;
SET request.jwt.claim.sub = '20000000-0000-0000-0000-000000000001';

INSERT INTO public.audit_logs (business_id,user_id,action)
VALUES (
  '10000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001',
  'member-write'
);

-- The SECURITY DEFINER trigger must still write an audit row with NULL user_id.
INSERT INTO public.audit_source (business_id)
VALUES ('10000000-0000-0000-0000-000000000001');

DO $test$
BEGIN
  IF (SELECT count(*) FROM public.audit_logs WHERE action='member-write') <> 1 THEN
    RAISE EXCEPTION 'Authorized member could not read its audit row';
  END IF;
  IF (SELECT count(*) FROM public.audit_logs WHERE action='trigger-write') <> 1 THEN
    RAISE EXCEPTION 'Trusted SECURITY DEFINER audit trigger was blocked';
  END IF;
END
$test$;

SET request.jwt.claim.sub = '20000000-0000-0000-0000-000000000002';

DO $test$
BEGIN
  IF EXISTS (SELECT 1 FROM public.audit_logs WHERE action IN ('member-write','trigger-write')) THEN
    RAISE EXCEPTION 'Cross-tenant audit row became visible';
  END IF;

  BEGIN
    INSERT INTO public.audit_logs (business_id,user_id,action)
    VALUES (
      '10000000-0000-0000-0000-000000000001',
      '20000000-0000-0000-0000-000000000002',
      'unauthorized-write'
    );
    RAISE EXCEPTION 'Cross-tenant insert unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$test$;
RESET ROLE;

SET ROLE anon;
DO $test$
BEGIN
  BEGIN
    PERFORM 1 FROM public.audit_logs;
    RAISE EXCEPTION 'anon SELECT unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$test$;
RESET ROLE;

SET ROLE service_role;
DO $test$
BEGIN
  IF (SELECT count(*) FROM public.audit_logs WHERE action='member-write') <> 1
     OR (SELECT count(*) FROM public.audit_logs WHERE action='trigger-write') <> 1 THEN
    RAISE EXCEPTION 'service_role cannot read all audit_logs';
  END IF;
END
$test$;
RESET ROLE;
