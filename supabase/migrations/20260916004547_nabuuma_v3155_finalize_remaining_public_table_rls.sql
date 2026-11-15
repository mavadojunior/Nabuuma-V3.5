BEGIN;

-- Deployment bootstrap is infrastructure state, not tenant data. Remove it from the Data API.
REVOKE ALL ON TABLE public._nabuuma_deployment_bootstrap FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public._nabuuma_deployment_bootstrap TO service_role;
ALTER TABLE public._nabuuma_deployment_bootstrap ENABLE ROW LEVEL SECURITY;
ALTER TABLE public._nabuuma_deployment_bootstrap FORCE ROW LEVEL SECURITY;

-- FEFO transfer-batch allocation lines are tenant-scoped operational evidence.
REVOKE ALL ON TABLE public.stock_transfer_batch_lines FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.stock_transfer_batch_lines FROM authenticated;
GRANT SELECT ON TABLE public.stock_transfer_batch_lines TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.stock_transfer_batch_lines TO service_role;
ALTER TABLE public.stock_transfer_batch_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS stock_transfer_batch_lines_select ON public.stock_transfer_batch_lines;
CREATE POLICY stock_transfer_batch_lines_select
  ON public.stock_transfer_batch_lines
  FOR SELECT
  TO authenticated
  USING ((SELECT public.is_member(business_id)));

-- No authenticated INSERT/UPDATE/DELETE policies are created deliberately:
-- allocation rows are created and mutated only inside the trusted transfer executor.

COMMIT;