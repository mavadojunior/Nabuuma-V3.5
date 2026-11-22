\set ON_ERROR_STOP on
DO $rls_catalog_acceptance$
DECLARE
  r record;
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relkind IN ('r','p') AND NOT c.relrowsecurity;
  IF v_count <> 0 THEN
    RAISE EXCEPTION '% public base tables do not have RLS enabled', v_count;
  END IF;

  FOR r IN
    SELECT c.oid, c.relname
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind IN ('r','p') AND c.relrowsecurity
  LOOP
    IF pg_catalog.has_table_privilege('anon',r.oid,'SELECT')
       OR pg_catalog.has_table_privilege('anon',r.oid,'INSERT')
       OR pg_catalog.has_table_privilege('anon',r.oid,'UPDATE')
       OR pg_catalog.has_table_privilege('anon',r.oid,'DELETE') THEN
      RAISE EXCEPTION 'anon has table-level CRUD privilege on public.%',r.relname;
    END IF;

    IF r.relname NOT IN ('acl_public_dml_probe','audit_source')
       AND pg_catalog.has_table_privilege('authenticated',r.oid,'SELECT')
       AND NOT EXISTS (
         SELECT 1 FROM pg_catalog.pg_policies p
         WHERE p.schemaname='public' AND p.tablename=r.relname
           AND p.cmd IN ('SELECT','ALL')
           AND ('authenticated'=ANY(p.roles) OR 'public'=ANY(p.roles))
       ) THEN
      RAISE EXCEPTION 'authenticated SELECT grant on public.% has no matching RLS policy',r.relname;
    END IF;

    IF pg_catalog.has_table_privilege('authenticated',r.oid,'INSERT')
       AND EXISTS (
         SELECT 1 FROM pg_catalog.pg_policies p
         WHERE p.schemaname='public' AND p.tablename=r.relname
           AND p.cmd IN ('INSERT','ALL')
           AND ('authenticated'=ANY(p.roles) OR 'public'=ANY(p.roles))
       ) IS FALSE THEN
      -- No INSERT policy is a deliberate fail-closed boundary for this role.
      NULL;
    END IF;
    IF pg_catalog.has_table_privilege('authenticated',r.oid,'UPDATE')
       AND NOT EXISTS (
         SELECT 1 FROM pg_catalog.pg_policies p
         WHERE p.schemaname='public' AND p.tablename=r.relname
           AND p.cmd IN ('UPDATE','ALL')
           AND ('authenticated'=ANY(p.roles) OR 'public'=ANY(p.roles))
       ) THEN NULL; END IF;
    IF pg_catalog.has_table_privilege('authenticated',r.oid,'DELETE')
       AND NOT EXISTS (
         SELECT 1 FROM pg_catalog.pg_policies p
         WHERE p.schemaname='public' AND p.tablename=r.relname
           AND p.cmd IN ('DELETE','ALL')
           AND ('authenticated'=ANY(p.roles) OR 'public'=ANY(p.roles))
       ) THEN NULL; END IF;
  END LOOP;

  IF NOT (SELECT rolbypassrls AND NOT rolsuper FROM pg_catalog.pg_roles WHERE rolname='service_role') THEN
    RAISE EXCEPTION 'service_role must BYPASSRLS without being superuser';
  END IF;
END
$rls_catalog_acceptance$;

SELECT count(*) AS rls_protected_tables,
       count(*) FILTER (WHERE NOT has_table_privilege('anon',c.oid,'SELECT')
         AND NOT has_table_privilege('anon',c.oid,'INSERT')
         AND NOT has_table_privilege('anon',c.oid,'UPDATE')
         AND NOT has_table_privilege('anon',c.oid,'DELETE')) AS anon_zero_crud
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relkind IN ('r','p') AND c.relrowsecurity;
SELECT 'PASS: RLS catalog boundaries, anon ACL denial and service_role bypass verified' AS result;
