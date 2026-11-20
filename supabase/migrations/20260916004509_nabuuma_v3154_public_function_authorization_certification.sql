BEGIN;

CREATE OR REPLACE FUNCTION public.v3154_authorization_certification()
RETURNS TABLE(
  public_security_definer_count bigint,
  authenticated_executable_count bigint,
  anon_executable_count bigint,
  mutable_search_path_security_definer_count bigint
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
  SELECT
    count(*) FILTER (WHERE p.prosecdef),
    count(*) FILTER (WHERE p.prosecdef AND has_function_privilege('authenticated', p.oid, 'EXECUTE')),
    count(*) FILTER (WHERE p.prosecdef AND has_function_privilege('anon', p.oid, 'EXECUTE')),
    count(*) FILTER (
      WHERE p.prosecdef
        AND NOT EXISTS (
          SELECT 1
          FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) AS cfg
          WHERE cfg LIKE 'search_path=%'
        )
    )
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public';
$$;

REVOKE EXECUTE ON FUNCTION public.v3154_authorization_certification() FROM anon, authenticated, PUBLIC;

COMMIT;