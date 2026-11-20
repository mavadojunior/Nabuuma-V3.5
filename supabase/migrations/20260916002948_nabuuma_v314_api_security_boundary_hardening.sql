BEGIN;

-- V3.14: close anonymous execution of every SECURITY DEFINER function currently exposed in public.
-- Keep authenticated execution unchanged until each function has an explicit application authorization contract.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS signature
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef = true
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', r.signature);
  END LOOP;
END $$;

-- Prevent newly-created public functions from inheriting broad API execution.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon;

-- Make the six flagged public views obey invoker RLS instead of creator privileges.
ALTER VIEW public.recipe_costs SET (security_invoker = true);
ALTER VIEW public.view_v20_location_reorder SET (security_invoker = true);
ALTER VIEW public.view_v22_logistics_control_tower SET (security_invoker = true);
ALTER VIEW public.view_v22_active_exceptions SET (security_invoker = true);
ALTER VIEW public.view_v23_replenishment_control_tower SET (security_invoker = true);
ALTER VIEW public.view_v29_learning_control_tower SET (security_invoker = true);

COMMIT;