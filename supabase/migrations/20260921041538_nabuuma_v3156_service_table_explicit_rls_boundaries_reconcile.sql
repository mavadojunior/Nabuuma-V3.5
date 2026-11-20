
BEGIN;
DO $$ BEGIN RAISE NOTICE 'V3.15.6: Applying explicit RLS rejection policies for 13 service-only tables'; END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'audit_logs','internal_state','deployment_config','migration_log','system_events',
    'feature_flags','cache_metadata','rate_limit_state','encryption_keys_metadata',
    'async_job_queue','distributed_lock_state','telemetry_events','service_health_state'
  ] LOOP
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name=t)
       AND NOT EXISTS (
         SELECT 1 FROM pg_policies
         WHERE schemaname='public' AND tablename=t AND policyname='reject_all_public_access'
       ) THEN
      EXECUTE format(
        'CREATE POLICY "reject_all_public_access" ON public.%I AS PERMISSIVE FOR ALL TO authenticated, anon USING (false) WITH CHECK (false)',
        t
      );
      RAISE NOTICE 'Policy created: %.reject_all_public_access', t;
    END IF;
  END LOOP;
END $$;

DO $$
DECLARE policy_count int;
BEGIN
  SELECT COUNT(*) INTO policy_count
  FROM pg_policies
  WHERE schemaname='public' AND policyname='reject_all_public_access';
  RAISE NOTICE 'Migration complete. Total reject_all_public_access policies: %', policy_count;
END $$;
COMMIT;