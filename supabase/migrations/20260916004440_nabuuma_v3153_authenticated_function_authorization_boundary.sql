BEGIN;

-- V3.15.3: no SECURITY DEFINER function in the exposed public schema is directly callable
-- by an authenticated client. Privileged execution remains available to the service role
-- and PostgreSQL owner; internal trigger/RLS callers are unaffected by EXECUTE ACLs.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS signature
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef = true
      AND pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated, anon, PUBLIC', r.signature);
  END LOOP;
END $$;

-- Prevent the same exposure on newly created functions owned by postgres.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM authenticated, anon, PUBLIC;

COMMIT;