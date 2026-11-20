-- ============================================================================
-- NABUUMA V3.15.7 — LEAST-PRIVILEGE GRANT HARDENING
-- AND ROW-LEVEL SECURITY ENFORCEMENT
--
-- Target project: mzfkamgfvxypakfkjdfs
-- Target relation: public.audit_logs
-- PostgreSQL target: 17.x
--
-- Security objectives:
--   1. Remove table-level and column-level privileges from PUBLIC, anon,
--      and authenticated before granting the minimum required client access.
--   2. Grant SELECT and INSERT only to authenticated.
--   3. Enable RLS without FORCE so trusted SECURITY DEFINER audit triggers retain owner execution.
--   4. Add migration-owned restrictive policies to preserve tenant boundaries
--      and deny UPDATE/DELETE even if permissive policies are added later.
--   5. Assert catalog state and effective privileges before committing.
--
-- Important limitations:
--   - The table owner (postgres) deliberately retains RLS bypass for trusted
--     SECURITY DEFINER trigger writers. This is a narrow internal exception.
--   - anon and authenticated are neither the table owner nor BYPASSRLS roles;
--     their effective access is constrained by the ACLs and RLS policies.
--   - service_role retains its existing BYPASSRLS operational behavior.
--   - This migration does not modify historical rows or table columns.
--   - Effective privilege assertions intentionally fail if inherited grants
--     still give client roles forbidden privileges.
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';
SET LOCAL search_path = pg_catalog, public, auth;

-- ============================================================================
-- PHASE 1 — LEAST-PRIVILEGE TABLE GRANTS RESET
-- ============================================================================

DO $migration$
DECLARE
    v_column record;
BEGIN
    IF to_regclass('public.audit_logs') IS NULL THEN
        RAISE EXCEPTION
            'V3.15.7 aborted: required relation public.audit_logs does not exist';
    END IF;

    -- Remove all table-level privileges from client-facing roles and PUBLIC.
    REVOKE ALL PRIVILEGES
        ON TABLE public.audit_logs
        FROM PUBLIC, anon, authenticated;

    -- REVOKE ALL ON TABLE does not remove column-level grants.
    -- Revoke column privileges separately for every existing user column.
    FOR v_column IN
        SELECT a.attname
        FROM pg_catalog.pg_attribute AS a
        WHERE a.attrelid = 'public.audit_logs'::regclass
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY a.attnum
    LOOP
        EXECUTE pg_catalog.format(
            'REVOKE ALL PRIVILEGES (%I) ON TABLE public.audit_logs '
            'FROM PUBLIC, anon, authenticated',
            v_column.attname
        );
    END LOOP;

    -- Minimum required table privileges for the authenticated API role.
    -- Existing permissive policies remain subject to the restrictive guards
    -- created in Phase 2.
    GRANT SELECT, INSERT
        ON TABLE public.audit_logs
        TO authenticated;

    -- Reassert the trusted Supabase service role's operational ACL explicitly.
    -- BYPASSRLS does not itself grant SQL table privileges.
    GRANT ALL PRIVILEGES
        ON TABLE public.audit_logs
        TO service_role;

    RAISE NOTICE
        'V3.15.7 Phase 1 complete: client grants reset; service_role grants retained';
END
$migration$;

-- ============================================================================
-- PHASE 2 — ENABLE/FORCE RLS AND INSTALL RESTRICTIVE TENANT GUARDS
-- ============================================================================

DO $migration$
BEGIN
    IF to_regclass('public.audit_logs') IS NULL THEN
        RAISE EXCEPTION
            'V3.15.7 aborted: public.audit_logs disappeared before Phase 2';
    END IF;

    -- Keep RLS enabled but do not FORCE it on this table. Production has
    -- SECURITY DEFINER trigger writers owned by postgres:
    --   audit_purchase_order_row_change_v1
    --   v21_audit_allocation_insert
    --   v22_audit_milestone
    -- Those trusted trigger functions write audit rows with differing user_id
    -- semantics. FORCE RLS would subject their writes to client INSERT guards.
    -- Client roles remain protected by ACLs and RLS; service_role has BYPASSRLS.
    ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
    ALTER TABLE public.audit_logs NO FORCE ROW LEVEL SECURITY;

    -- The production V3.15.6 reconciliation added a PERMISSIVE false policy.
    -- It does not deny access when other permissive policies apply, but it is
    -- obsolete on this tenant-scoped table and is removed for clarity.
    DROP POLICY IF EXISTS reject_all_public_access ON public.audit_logs;

    -- Migration-owned SELECT guard.
    -- Any applicable permissive SELECT policy must also satisfy membership.
    DROP POLICY IF EXISTS v3157_audit_logs_select_guard
        ON public.audit_logs;

    CREATE POLICY v3157_audit_logs_select_guard
        ON public.audit_logs
        AS RESTRICTIVE
        FOR SELECT
        TO PUBLIC
        USING (public.is_member(business_id));

    -- Migration-owned INSERT guard.
    -- Both business membership and the authenticated user's identity
    -- must match the row being inserted.
    DROP POLICY IF EXISTS v3157_audit_logs_insert_guard
        ON public.audit_logs;

    CREATE POLICY v3157_audit_logs_insert_guard
        ON public.audit_logs
        AS RESTRICTIVE
        FOR INSERT
        TO PUBLIC
        WITH CHECK (
            public.is_member(business_id)
            AND user_id = (SELECT auth.uid())
        );

    -- Deny UPDATE even if a future permissive UPDATE policy is added.
    DROP POLICY IF EXISTS v3157_audit_logs_update_deny
        ON public.audit_logs;

    CREATE POLICY v3157_audit_logs_update_deny
        ON public.audit_logs
        AS RESTRICTIVE
        FOR UPDATE
        TO PUBLIC
        USING (false)
        WITH CHECK (false);

    -- Deny DELETE even if a future permissive DELETE policy is added.
    DROP POLICY IF EXISTS v3157_audit_logs_delete_deny
        ON public.audit_logs;

    CREATE POLICY v3157_audit_logs_delete_deny
        ON public.audit_logs
        AS RESTRICTIVE
        FOR DELETE
        TO PUBLIC
        USING (false);

    RAISE NOTICE
        'V3.15.7 Phase 2 complete: RLS enabled without FORCE and restrictive guards installed';
END
$migration$;

-- ============================================================================
-- PHASE 3 — POST-EXECUTION CATALOG AND PRIVILEGE ASSERTIONS
-- Any failed assertion aborts the transaction.
-- ============================================================================

DO $migration$
DECLARE
    v_relation_oid       oid;
    v_rls_enabled        boolean;
    v_rls_forced         boolean;
    v_pg_tables_rls      boolean;
    v_privilege          text;
    v_service_bypass     boolean;
BEGIN
    v_relation_oid := to_regclass('public.audit_logs');

    IF v_relation_oid IS NULL THEN
        RAISE EXCEPTION
            'V3.15.7 verification failed: public.audit_logs is missing';
    END IF;

    -- Verify relation catalog flags.
    SELECT c.relrowsecurity, c.relforcerowsecurity
      INTO v_rls_enabled, v_rls_forced
      FROM pg_catalog.pg_class AS c
     WHERE c.oid = v_relation_oid
       AND c.relkind IN ('r', 'p');

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'V3.15.7 verification failed: target is not a supported table';
    END IF;

    IF v_rls_enabled IS DISTINCT FROM true THEN
        RAISE EXCEPTION
            'V3.15.7 verification failed: RLS is not enabled';
    END IF;

    IF v_rls_forced IS DISTINCT FROM false THEN
        RAISE EXCEPTION
            'V3.15.7 verification failed: FORCE ROW LEVEL SECURITY must remain disabled for trusted audit triggers';
    END IF;

    -- Independently verify the pg_tables row-security marker.
    SELECT t.rowsecurity
      INTO v_pg_tables_rls
      FROM pg_catalog.pg_tables AS t
     WHERE t.schemaname = 'public'
       AND t.tablename = 'audit_logs';

    IF NOT FOUND OR v_pg_tables_rls IS DISTINCT FROM true THEN
        RAISE EXCEPTION
            'V3.15.7 verification failed: pg_tables rowsecurity marker is not true';
    END IF;

    -- Verify authenticated retains exactly the intended table-level
    -- SELECT/INSERT capabilities among the listed table privileges.
    IF NOT pg_catalog.has_table_privilege(
        'authenticated', v_relation_oid, 'SELECT'
    ) THEN
        RAISE EXCEPTION
            'V3.15.7 verification failed: authenticated lacks SELECT';
    END IF;

    IF NOT pg_catalog.has_table_privilege(
        'authenticated', v_relation_oid, 'INSERT'
    ) THEN
        RAISE EXCEPTION
            'V3.15.7 verification failed: authenticated lacks INSERT';
    END IF;

    -- anon must not retain any effective table-level privilege.
    IF pg_catalog.has_table_privilege(
           'anon', v_relation_oid, 'SELECT'
       )
       OR pg_catalog.has_table_privilege(
           'anon', v_relation_oid, 'INSERT'
       )
       OR pg_catalog.has_table_privilege(
           'anon', v_relation_oid, 'UPDATE'
       )
       OR pg_catalog.has_table_privilege(
           'anon', v_relation_oid, 'DELETE'
       )
       OR pg_catalog.has_table_privilege(
           'anon', v_relation_oid, 'TRUNCATE'
       )
       OR pg_catalog.has_table_privilege(
           'anon', v_relation_oid, 'REFERENCES'
       )
       OR pg_catalog.has_table_privilege(
           'anon', v_relation_oid, 'TRIGGER'
       )
       OR pg_catalog.has_table_privilege(
           'anon', v_relation_oid, 'MAINTAIN'
       ) THEN
        RAISE EXCEPTION
            'V3.15.7 verification failed: anon retains an effective table privilege';
    END IF;

    -- These privileges must not be effective for authenticated.
    FOREACH v_privilege IN ARRAY ARRAY[
        'UPDATE',
        'DELETE',
        'TRUNCATE',
        'TRIGGER',
        'REFERENCES',
        'MAINTAIN'
    ]
    LOOP
        IF pg_catalog.has_table_privilege(
            'authenticated', v_relation_oid, v_privilege
        ) THEN
            RAISE EXCEPTION
                'V3.15.7 verification failed: authenticated retains % privilege',
                v_privilege;
        END IF;
    END LOOP;

    -- Confirm the legacy permissive false policy is gone from this tenant-scoped table.
    IF EXISTS (
        SELECT 1
          FROM pg_catalog.pg_policies AS p
         WHERE p.schemaname = 'public'
           AND p.tablename = 'audit_logs'
           AND p.policyname = 'reject_all_public_access'
    ) THEN
        RAISE EXCEPTION
            'V3.15.7 verification failed: legacy permissive false policy remains';
    END IF;

    -- Confirm the migration-owned restrictive policy set exists.
    IF (
        SELECT count(*)
          FROM pg_catalog.pg_policies AS p
         WHERE p.schemaname = 'public'
           AND p.tablename = 'audit_logs'
           AND p.policyname IN (
               'v3157_audit_logs_select_guard',
               'v3157_audit_logs_insert_guard',
               'v3157_audit_logs_update_deny',
               'v3157_audit_logs_delete_deny'
           )
           AND p.permissive = 'RESTRICTIVE'
    ) <> 4 THEN
        RAISE EXCEPTION
            'V3.15.7 verification failed: restrictive policy set is incomplete';
    END IF;

    -- Column-level grants are independent of table-level grants. Verify the
    -- effective client boundary for every column privilege PostgreSQL supports.
    IF pg_catalog.has_any_column_privilege('anon', v_relation_oid, 'SELECT')
       OR pg_catalog.has_any_column_privilege('anon', v_relation_oid, 'INSERT')
       OR pg_catalog.has_any_column_privilege('anon', v_relation_oid, 'UPDATE')
       OR pg_catalog.has_any_column_privilege('anon', v_relation_oid, 'REFERENCES')
       OR pg_catalog.has_any_column_privilege('authenticated', v_relation_oid, 'UPDATE')
       OR pg_catalog.has_any_column_privilege('authenticated', v_relation_oid, 'REFERENCES') THEN
        RAISE EXCEPTION
            'V3.15.7 verification failed: forbidden effective column privilege remains';
    END IF;

    -- service_role must retain its explicit operational grants after PUBLIC and
    -- client grants are revoked. BYPASSRLS does not bypass SQL privileges.
    FOREACH v_privilege IN ARRAY ARRAY[
        'SELECT', 'INSERT', 'UPDATE', 'DELETE',
        'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'
    ]
    LOOP
        IF NOT pg_catalog.has_table_privilege(
            'service_role', v_relation_oid, v_privilege
        ) THEN
            RAISE EXCEPTION
                'V3.15.7 verification failed: service_role lacks % privilege',
                v_privilege;
        END IF;
    END LOOP;

    SELECT r.rolbypassrls
      INTO v_service_bypass
      FROM pg_catalog.pg_roles AS r
     WHERE r.rolname = 'service_role';
    IF v_service_bypass IS DISTINCT FROM true THEN
        RAISE EXCEPTION
            'V3.15.7 verification failed: service_role must retain BYPASSRLS';
    END IF;

    RAISE NOTICE
        'V3.15.7 verification passed: RLS enabled and not forced; trusted audit triggers retained; '
        'legacy false policy removed; '
        'anon has no effective privileges; authenticated has SELECT/INSERT only; '
        'service_role retains operational grants; four restrictive guards exist.';
END
$migration$;

COMMIT;

-- ============================================================================
-- END V3.15.7
--
-- Deployment note:
-- This migration does not prove that superusers or BYPASSRLS roles are subject
-- to RLS. It does not audit function EXECUTE privileges, schema USAGE,
-- sequence privileges, role memberships, direct partition access, or grants
-- on other objects. Review those paths separately before certifying the
-- complete production security perimeter.
-- ============================================================================
