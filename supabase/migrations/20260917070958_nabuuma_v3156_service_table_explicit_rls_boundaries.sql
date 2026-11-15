BEGIN;

-- Service-only control-plane tables: explicit deny policies for exposed anon/authenticated roles.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'gcc_invoice_sequences',
    'network_break_glass_authorizations',
    'network_break_glass_events',
    'network_founder_identity_registry',
    'network_ip_provenance_events',
    'network_platform_ip_asset_versions',
    'network_platform_ip_assets',
    'network_root_key_registry',
    'network_signing_workflow_signatures',
    'network_signing_workflows'
  ]
  LOOP
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM anon, authenticated', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO service_role', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_deny_client_access', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO anon, authenticated USING (false)', t || '_deny_client_access', t);
  END LOOP;
END $$;

-- users: authenticated users may read only their own profile; writes remain service_role-only.
REVOKE ALL ON TABLE public.users FROM anon, authenticated;
GRANT SELECT ON TABLE public.users TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.users TO service_role;
DROP POLICY IF EXISTS users_self_select ON public.users;
CREATE POLICY users_self_select
  ON public.users
  FOR SELECT
  TO authenticated
  USING ((SELECT auth.uid()) = id);

-- Stock-transfer recommendations are tenant-scoped operational data, not service-only metadata.
REVOKE ALL ON TABLE public.stock_transfer_recommendations FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.stock_transfer_recommendations FROM authenticated;
GRANT SELECT ON TABLE public.stock_transfer_recommendations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.stock_transfer_recommendations TO service_role;
DROP POLICY IF EXISTS stock_transfer_recommendations_select ON public.stock_transfer_recommendations;
CREATE POLICY stock_transfer_recommendations_select
  ON public.stock_transfer_recommendations
  FOR SELECT
  TO authenticated
  USING ((SELECT public.is_member(business_id)));

COMMIT;