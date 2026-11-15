-- V3.15.6: Restrict client access to service-only audit logs.
-- Scope: public.audit_logs, verified to exist in the target database.
-- Client roles: anon and authenticated.
-- Service-role access remains governed by its grants and RLS bypass privileges.

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'V3.15.6 requires public.audit_logs to exist';
  END IF;
END
$$;

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

-- Replace any previous version of this policy so its definition is deterministic.
DROP POLICY IF EXISTS reject_all_public_access ON public.audit_logs;

-- RESTRICTIVE ensures this denial combines with existing permissive policies
-- using AND, rather than allowing an existing policy to grant client access.
CREATE POLICY reject_all_public_access
  ON public.audit_logs
  AS RESTRICTIVE
  FOR ALL
  TO anon, authenticated
  USING (false)
  WITH CHECK (false);

COMMIT;
