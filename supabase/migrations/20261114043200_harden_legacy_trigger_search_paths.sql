-- Harden the two legacy SECURITY DEFINER trigger functions identified during
-- production parity review. Their application objects are schema-qualified;
-- pg_catalog is sufficient for built-in functions and trigger variables.
BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';

ALTER FUNCTION public.v21_audit_allocation_insert()
    SET search_path = pg_catalog;

ALTER FUNCTION public.v22_audit_milestone()
    SET search_path = pg_catalog;

COMMIT;
