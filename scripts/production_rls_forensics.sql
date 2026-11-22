\set ON_ERROR_STOP on
\pset pager off
\pset border 2
\pset null '[NULL]'
\pset format aligned

\echo
\echo '=============================================================='
\echo ' NABUUMA V3.15.6 — PRODUCTION RLS FORENSICS'
\echo ' READ-ONLY CATALOG AUDIT'
\echo '=============================================================='

BEGIN TRANSACTION READ ONLY;

\echo
\echo 'MODULE A — RELATION EXISTENCE, RLS ACTIVATION AND ENFORCEMENT'
\echo

WITH targets(table_name) AS (
    VALUES
        ('audit_logs'),
        ('internal_state'),
        ('deployment_config'),
        ('migration_log'),
        ('system_events'),
        ('feature_flags'),
        ('cache_metadata'),
        ('rate_limit_state'),
        ('encryption_keys_metadata'),
        ('async_job_queue'),
        ('distributed_lock_state'),
        ('telemetry_events'),
        ('service_health_state')
)
SELECT
    t.table_name AS target_table,
    CASE
        WHEN c.oid IS NULL THEN 'MISSING'
        ELSE 'EXISTS'
    END AS relation_status,
    c.relkind AS relation_kind,
    pg_catalog.pg_get_userbyid(c.relowner) AS owner,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced,
    pt.rowsecurity AS pg_tables_rls_status,
    CASE
        WHEN c.oid IS NULL THEN 'NO RELATION'
        WHEN c.relkind NOT IN ('r', 'p') THEN
            'NOT A TABLE / PARTITIONED TABLE'
        WHEN NOT c.relrowsecurity THEN
            'RLS DISABLED'
        WHEN c.relforcerowsecurity THEN
            'RLS ENABLED AND FORCED'
        ELSE
            'RLS ENABLED; OWNER MAY BYPASS'
    END AS assessment
FROM targets AS t
LEFT JOIN pg_catalog.pg_namespace AS n
    ON n.nspname = 'public'
LEFT JOIN pg_catalog.pg_class AS c
    ON c.relnamespace = n.oid
   AND c.relname = t.table_name
LEFT JOIN pg_catalog.pg_tables AS pt
    ON pt.schemaname = 'public'
   AND pt.tablename = t.table_name
ORDER BY t.table_name;


\echo
\echo 'MODULE B — COMPLETE POLICY SEMANTIC INVENTORY'
\echo 'One row per policy. No policy means no row in this report.'
\echo

WITH targets(table_name) AS (
    VALUES
        ('audit_logs'),
        ('internal_state'),
        ('deployment_config'),
        ('migration_log'),
        ('system_events'),
        ('feature_flags'),
        ('cache_metadata'),
        ('rate_limit_state'),
        ('encryption_keys_metadata'),
        ('async_job_queue'),
        ('distributed_lock_state'),
        ('telemetry_events'),
        ('service_health_state')
)
SELECT
    p.schemaname AS schema_name,
    p.tablename AS table_name,
    p.policyname AS policy_name,
    p.permissive AS policy_type,
    p.cmd AS command,
    p.roles AS applicable_roles,
    p.qual AS using_expression,
    p.with_check AS with_check_expression
FROM pg_catalog.pg_policies AS p
JOIN targets AS t
    ON t.table_name = p.tablename
WHERE p.schemaname = 'public'
ORDER BY
    p.tablename,
    p.cmd,
    p.permissive,
    p.policyname;


\echo
\echo 'MODULE C1 — POLICY AGGREGATION BY TABLE AND COMMAND'
\echo 'Counts indicate policy structure, not a proof of exploitability.'
\echo

WITH targets(table_name) AS (
    VALUES
        ('audit_logs'),
        ('internal_state'),
        ('deployment_config'),
        ('migration_log'),
        ('system_events'),
        ('feature_flags'),
        ('cache_metadata'),
        ('rate_limit_state'),
        ('encryption_keys_metadata'),
        ('async_job_queue'),
        ('distributed_lock_state'),
        ('telemetry_events'),
        ('service_health_state')
),
commands(command_name) AS (
    VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')
),
inventory AS (
    SELECT
        p.tablename,
        p.cmd,
        p.policyname,
        p.permissive,
        p.roles,
        p.qual,
        p.with_check
    FROM pg_catalog.pg_policies AS p
    JOIN targets AS t
        ON t.table_name = p.tablename
    WHERE p.schemaname = 'public'
)
SELECT
    t.table_name,
    cmd.command_name,
    COUNT(i.policyname) AS policy_count,
    COUNT(i.policyname) FILTER (
        WHERE i.permissive = 'PERMISSIVE'
    ) AS permissive_policy_count,
    COUNT(i.policyname) FILTER (
        WHERE i.permissive = 'RESTRICTIVE'
    ) AS restrictive_policy_count,
    COUNT(i.policyname) FILTER (
        WHERE i.permissive = 'PERMISSIVE'
          AND i.policyname <> 'reject_all_public_access'
    ) AS other_permissive_policy_count,
    COUNT(i.policyname) FILTER (
        WHERE i.policyname = 'reject_all_public_access'
          AND i.permissive = 'PERMISSIVE'
    ) AS named_permissive_rejection_count,
    COUNT(i.policyname) FILTER (
        WHERE i.policyname = 'reject_all_public_access'
          AND i.permissive = 'RESTRICTIVE'
    ) AS named_restrictive_rejection_count,
    CASE
        WHEN COUNT(i.policyname) = 0 THEN 'NO POLICY'
        WHEN COUNT(i.policyname) FILTER (
            WHERE i.permissive = 'PERMISSIVE'
        ) > 1 THEN 'MULTIPLE PERMISSIVE POLICIES'
        WHEN COUNT(i.policyname) FILTER (
            WHERE i.permissive = 'PERMISSIVE'
        ) = 1
         AND COUNT(i.policyname) FILTER (
            WHERE i.permissive = 'RESTRICTIVE'
        ) > 0 THEN 'PERMISSIVE + RESTRICTIVE'
        ELSE 'REVIEW POLICY EXPRESSIONS'
    END AS structural_assessment
FROM targets AS t
CROSS JOIN commands AS cmd
LEFT JOIN inventory AS i
    ON i.tablename = t.table_name
   AND (
       i.cmd = cmd.command_name
       OR i.cmd = 'ALL'
   )
GROUP BY t.table_name, cmd.command_name
ORDER BY t.table_name, cmd.command_name;


\echo
\echo 'MODULE C2 — TABLE-WIDE FALSE-POLICY CANDIDATES'
\echo 'Counts are table-wide, not scoped by command or role.'
\echo 'Text matching is indicative; inspect Module B for semantics.'
\echo

WITH targets(table_name) AS (
    VALUES
        ('audit_logs'),
        ('internal_state'),
        ('deployment_config'),
        ('migration_log'),
        ('system_events'),
        ('feature_flags'),
        ('cache_metadata'),
        ('rate_limit_state'),
        ('encryption_keys_metadata'),
        ('async_job_queue'),
        ('distributed_lock_state'),
        ('telemetry_events'),
        ('service_health_state')
),
policies AS (
    SELECT
        p.tablename,
        p.policyname,
        p.permissive,
        p.cmd,
        p.roles,
        p.qual,
        p.with_check
    FROM pg_catalog.pg_policies AS p
    JOIN targets AS t
        ON t.table_name = p.tablename
    WHERE p.schemaname = 'public'
)
SELECT
    t.table_name,
    EXISTS (
        SELECT 1
        FROM policies AS p
        WHERE p.tablename = t.table_name
          AND p.policyname = 'reject_all_public_access'
          AND p.permissive = 'PERMISSIVE'
          AND (
              p.qual = 'false'
              OR p.with_check = 'false'
          )
    ) AS has_named_false_permissive_candidate,
    EXISTS (
        SELECT 1
        FROM policies AS p
        WHERE p.tablename = t.table_name
          AND p.permissive = 'PERMISSIVE'
          AND (
              p.qual = 'false'
              OR p.with_check = 'false'
          )
    ) AS has_any_false_permissive_candidate,
    COUNT(*) FILTER (
        WHERE p.permissive = 'PERMISSIVE'
          AND p.policyname <> 'reject_all_public_access'
    ) AS other_permissive_policy_count,
    COUNT(*) FILTER (
        WHERE p.permissive = 'RESTRICTIVE'
    ) AS restrictive_policy_count,
    COALESCE(
        string_agg(
            format(
                '%s [cmd=%s, roles=%s, USING=%s, CHECK=%s]',
                p.policyname,
                p.cmd,
                p.roles,
                COALESCE(p.qual, '<none>'),
                COALESCE(p.with_check, '<none>')
            ),
            E'\n'
            ORDER BY p.policyname
        ) FILTER (WHERE p.policyname IS NOT NULL),
        '<no policies found>'
    ) AS policy_details
FROM targets AS t
LEFT JOIN policies AS p
    ON p.tablename = t.table_name
GROUP BY t.table_name
ORDER BY t.table_name;


\echo
\echo 'MODULE D1 — EXPLICIT TABLE ACL ENTRIES'
\echo 'ACL entries are grants, not RLS policies.'
\echo

WITH targets(table_name) AS (
    VALUES
        ('audit_logs'),
        ('internal_state'),
        ('deployment_config'),
        ('migration_log'),
        ('system_events'),
        ('feature_flags'),
        ('cache_metadata'),
        ('rate_limit_state'),
        ('encryption_keys_metadata'),
        ('async_job_queue'),
        ('distributed_lock_state'),
        ('telemetry_events'),
        ('service_health_state')
)
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    CASE
        WHEN acl.grantee = 0 THEN 'PUBLIC'
        ELSE COALESCE(grantee.rolname, '<unknown role>')
    END AS grantee,
    grantor.rolname AS grantor,
    acl.privilege_type,
    acl.is_grantable
FROM pg_catalog.pg_class AS c
JOIN pg_catalog.pg_namespace AS n
    ON n.oid = c.relnamespace
JOIN targets AS t
    ON t.table_name = c.relname
CROSS JOIN LATERAL pg_catalog.aclexplode(
    COALESCE(
        c.relacl,
        pg_catalog.acldefault('r', c.relowner)
    )
) AS acl
LEFT JOIN pg_catalog.pg_roles AS grantee
    ON grantee.oid = acl.grantee
LEFT JOIN pg_catalog.pg_roles AS grantor
    ON grantor.oid = acl.grantor
WHERE n.nspname = 'public'
  AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
ORDER BY c.relname, grantee, acl.privilege_type;


\echo
\echo 'MODULE D2 — EFFECTIVE TABLE PRIVILEGES FOR KEY ROLES'
\echo 'Includes inherited grants and PUBLIC grants via PostgreSQL.'
\echo 'A missing role is reported as absent rather than assumed.'
\echo

WITH targets(table_name) AS (
    VALUES
        ('audit_logs'),
        ('internal_state'),
        ('deployment_config'),
        ('migration_log'),
        ('system_events'),
        ('feature_flags'),
        ('cache_metadata'),
        ('rate_limit_state'),
        ('encryption_keys_metadata'),
        ('async_job_queue'),
        ('distributed_lock_state'),
        ('telemetry_events'),
        ('service_health_state')
),
key_roles(role_name) AS (
    VALUES
        ('anon'),
        ('authenticated'),
        ('service_role')
),
privileges(privilege_name) AS (
    VALUES
        ('SELECT'),
        ('INSERT'),
        ('UPDATE'),
        ('DELETE'),
        ('TRUNCATE'),
        ('REFERENCES'),
        ('TRIGGER')
)
SELECT
    t.table_name,
    kr.role_name,
    CASE
        WHEN r.oid IS NULL THEN 'ROLE MISSING'
        ELSE 'ROLE EXISTS'
    END AS role_status,
    r.rolsuper AS is_superuser,
    r.rolbypassrls AS bypasses_rls,
    string_agg(
        CASE
            WHEN r.oid IS NULL THEN NULL
            WHEN c.oid IS NULL THEN NULL
            WHEN pg_catalog.has_table_privilege(
                r.oid, c.oid, priv.privilege_name
            ) THEN priv.privilege_name
        END,
        ', '
        ORDER BY priv.privilege_name
    ) AS effective_table_privileges
FROM targets AS t
CROSS JOIN key_roles AS kr
LEFT JOIN pg_catalog.pg_roles AS r
    ON r.rolname = kr.role_name
LEFT JOIN pg_catalog.pg_namespace AS n
    ON n.nspname = 'public'
LEFT JOIN pg_catalog.pg_class AS c
    ON c.relnamespace = n.oid
   AND c.relname = t.table_name
   AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
CROSS JOIN privileges AS priv
GROUP BY
    t.table_name,
    kr.role_name,
    r.oid,
    r.rolsuper,
    r.rolbypassrls,
    c.oid
ORDER BY t.table_name, kr.role_name;


\echo
\echo 'MODULE D3 — ROLE ATTRIBUTES'
\echo 'Superusers and BYPASSRLS roles bypass ordinary RLS enforcement.'
\echo

SELECT
    r.rolname AS role_name,
    r.rolsuper AS is_superuser,
    r.rolbypassrls AS bypasses_rls,
    r.rolinherit AS inherits_role_privileges,
    r.rolcanlogin AS can_login
FROM pg_catalog.pg_roles AS r
WHERE r.rolname IN (
    'anon',
    'authenticated',
    'service_role'
)
ORDER BY r.rolname;


\echo
\echo '=============================================================='
\echo ' AUDIT COMPLETE — READ-ONLY TRANSACTION'
\echo ' No schema or data changes were requested by this script.'
\echo '=============================================================='

COMMIT;
