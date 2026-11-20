BEGIN;

DROP POLICY IF EXISTS _nabuuma_deployment_bootstrap_deny_client_access ON public._nabuuma_deployment_bootstrap;
CREATE POLICY _nabuuma_deployment_bootstrap_deny_client_access
  ON public._nabuuma_deployment_bootstrap
  FOR SELECT
  TO anon, authenticated
  USING (false);

COMMIT;