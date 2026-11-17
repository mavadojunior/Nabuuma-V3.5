-- Restore client ACL boundaries that are present in the repository migration
-- history but have been broadened in the live production ACL catalog.
-- This migration is intentionally separate from structural schema recovery.
BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';
SET LOCAL search_path = pg_catalog, public, extensions, auth;

-- TRUNCATE bypasses RLS. MAINTAIN, REFERENCES and TRIGGER are not required by
-- the PostgREST client roles. Remove these non-DML privileges from every
-- public base table, while retaining ordinary CRUD privileges for RLS policies.
DO $client_non_dml$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT n.nspname, c.relname
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
    LOOP
        -- PUBLIC membership is inherited by every API role. No public base
        -- table should expose direct DML to all roles.
        EXECUTE format(
            'REVOKE INSERT, UPDATE, DELETE ON TABLE %I.%I FROM PUBLIC',
            r.nspname,
            r.relname
        );
        EXECUTE format(
            'REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE %I.%I FROM PUBLIC, anon, authenticated',
            r.nspname,
            r.relname
        );
    END LOOP;
END;
$client_non_dml$;

-- Public views are derived read surfaces. Production inspection confirmed
-- that all 12 current public views are security-invoker and non-updatable.
-- Preserve API read access while removing every write/DDL-style privilege
-- from the client roles, including inherited grants through PUBLIC.
DO $client_view_acl$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT c.relname
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind = 'v'
    LOOP
        EXECUTE format(
            'REVOKE ALL PRIVILEGES ON TABLE public.%I FROM PUBLIC, anon, authenticated, service_role',
            r.relname
        );
        EXECUTE format(
            'GRANT SELECT ON TABLE public.%I TO anon, authenticated, service_role',
            r.relname
        );
    END LOOP;
END;
$client_view_acl$;

-- Prevent non-DML client privileges on future public objects created by the
-- migration role. Production postgres is not a member of supabase_admin and is
-- not a superuser, so it cannot alter that platform-owned role's default ACL.
-- Do not attempt ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin here: it would
-- abort the entire migration in the actual production permission context.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLES FROM PUBLIC, anon, authenticated;

-- Future application objects are private by default. Existing objects retain
-- their current grants; migrations must explicitly grant only the access they
-- require. Keep these defaults scoped to the postgres migration owner.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
REVOKE ALL ON TABLES FROM anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
REVOKE ALL ON SEQUENCES FROM anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
REVOKE ALL ON FUNCTIONS FROM anon, authenticated, service_role;

-- PostgreSQL grants EXECUTE to PUBLIC by default for every new function.
-- This global default revoke is required: a schema-specific revoke cannot
-- cancel the global PUBLIC default. It applies to every schema for functions
-- created by postgres. Future RPCs and RLS helper functions need explicit
-- EXECUTE grants to their intended callers. Existing function ACLs are unchanged.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres
REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Service-only control-plane tables. These ACLs are already specified by
-- 20260917070958; reassert them because production currently has client grants.
DO $service_only$
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
        'network_signing_workflows',
        '_nabuuma_deployment_bootstrap'
    ]
    LOOP
        EXECUTE format(
            'REVOKE ALL PRIVILEGES ON TABLE public.%I FROM PUBLIC, anon, authenticated',
            t
        );
    END LOOP;
END;
$service_only$;

-- User profiles are readable by authenticated users only; writes are service-only.
REVOKE ALL PRIVILEGES ON TABLE public.users FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.users TO authenticated;

-- Recommendations are tenant-readable, but all writes remain service-role-only.
-- Revoke ALL rather than only INSERT/UPDATE/DELETE so TRUNCATE/MAINTAIN cannot
-- survive inherited/default grants.
REVOKE ALL PRIVILEGES ON TABLE public.stock_transfer_recommendations
FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.stock_transfer_recommendations TO authenticated;

-- Explicit read/read-write client boundaries from the recovered migrations.
DO $restricted_client_tables$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'gcc_cross_border_pod',
        'gcc_ledger_exchange_rates',
        'network_dispatched_receipts',
        'network_ledger_continuity_checks',
        'network_ledger_forensic_certifications',
        'network_ledger_forensic_events',
        'network_ledger_repair_lines',
        'supplier_delivery_commitments',
        'supplier_logistics_events',
        'v22_financial_forensic_ledger',
        'v22_logistics_financial_valuations',
        'v22_logistics_milestones',
        'v22_logistics_shipments'
    ]
    LOOP
        EXECUTE format(
            'REVOKE ALL PRIVILEGES ON TABLE public.%I FROM PUBLIC, anon, authenticated',
            t
        );
    END LOOP;
END;
$restricted_client_tables$;

GRANT SELECT ON TABLE
    public.gcc_cross_border_pod,
    public.gcc_ledger_exchange_rates,
    public.network_ledger_continuity_checks,
    public.network_ledger_forensic_certifications,
    public.network_ledger_forensic_events,
    public.network_ledger_repair_lines,
    public.v22_financial_forensic_ledger,
    public.v22_logistics_financial_valuations,
    public.v22_logistics_milestones,
    public.v22_logistics_shipments
TO authenticated;

GRANT SELECT, INSERT ON TABLE
    public.network_dispatched_receipts,
    public.supplier_delivery_commitments,
    public.supplier_logistics_events
TO authenticated;

-- Full effective relation-ACL reconciliation.
-- The original table/relation drift snapshot contained 329 role/relation rows
-- and 1,408 privilege bits. The public-view audit added 35 further rows and
-- 244 additional excess bits after retaining SELECT on all 12 views.
-- Together, 364 rows and 1,652 excess privilege bits are reconciled below.
-- Production-only relation grants absent from the 69-migration replay plus V3.15.7.
-- These REVOKEs bring current public relation ACLs back to the recovered migration state.
-- Keep the groups explicit so each table/role boundary can be reviewed.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public.network_audit_stream, public.network_contract_lines, public.network_contract_negotiation_lines, public.network_contract_negotiations, public.network_contract_signatures, public.network_contracts, public.network_dispatches_disputes, public.network_key_rotation_logs, public.network_order_dispatch_lines, public.network_order_dispatches, public.network_organization_verifications, public.network_organizations, public.network_sales_order_lines, public.network_sales_orders, public.network_tenant_keys FROM anon;
REVOKE SELECT, INSERT ON TABLE public.network_ledger_forensic_events FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLE public._nabuuma_deployment_bootstrap, public.exchange_rates, public.financial_accounts, public.financial_ledger_entries, public.fta_audit_log, public.gcc_cross_border_escrow, public.gcc_cross_border_manifest_lines, public.gcc_cross_border_manifests, public.gcc_cross_border_pod, public.gcc_customs_events, public.gcc_customs_hs_tariffs, public.gcc_data_residency_lineage, public.gcc_invoice_sequences, public.gcc_ledger_exchange_rates, public.gcc_supported_currencies, public.gcc_tax_business_access, public.gcc_tax_ledger, public.multi_tenant_escrow_controls, public.network_break_glass_authorizations, public.network_break_glass_events, public.network_dispatch_financial_clearances, public.network_dispatched_receipts, public.network_evidence_oracles, public.network_evidence_verification_events, public.network_financial_divergences, public.network_financial_finality_gates, public.network_financial_finality_requirements, public.network_financial_repair_events, public.network_financial_repairs, public.network_founder_identity_registry, public.network_invoice_lines, public.network_invoices, public.network_ip_provenance_events, public.network_ledger_continuity_checks, public.network_ledger_forensic_certifications, public.network_ledger_repair_lines, public.network_liquidity_reservations, public.network_liquidity_sources, public.network_oracle_evidence, public.network_platform_ip_asset_versions, public.network_platform_ip_assets, public.network_reconciliation_runs, public.network_root_key_registry, public.network_settlement_route_legs, public.network_settlement_routes, public.network_settlement_routing_events, public.network_signing_workflow_signatures, public.network_signing_workflows, public.settlement_batch_lines, public.settlement_batches, public.stock_transfer_batch_lines, public.stock_transfer_recommendations, public.supplier_delivery_commitments, public.supplier_logistics_events, public.users, public.v22_financial_forensic_ledger, public.v22_logistics_financial_valuations, public.v22_logistics_milestones, public.v22_logistics_shipments, public.v29_learning_outcomes, public.v29_policy_candidates, public.v29_policy_evaluations FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public.audit_logs FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public.assessments, public.business_members, public.businesses, public.certifications, public.courses, public.demand_forecasts, public.goods_receipt_lines, public.goods_receipts, public.ingredient_batches, public.ingredient_daily_consumption, public.ingredient_prices, public.ingredients, public.inventory_batches, public.inventory_execution_failures, public.inventory_execution_receipts, public.inventory_ledger_entries, public.inventory_ledger_transactions, public.inventory_locations, public.inventory_movements, public.inventory_service_targets, public.inventory_transfer_lines, public.inventory_transfers, public.locations, public.products, public.purchase_order_lines, public.purchase_orders, public.purchase_plan_lines, public.purchase_plans, public.qc_checks, public.recipe_ingredients, public.recipe_versions, public.routing_deficit_bypasses, public.routing_execution_logs, public.service_events, public.staff_profiles, public.stock_transfer_lines, public.stock_transfers, public.subscriptions, public.supplier_execution_metrics, public.supplier_ingredient_terms, public.supplier_recommendations, public.suppliers, public.supply_automation_events, public.supply_automation_runs, public.supply_recovery_actions, public.supply_recovery_approvals, public.supply_recovery_outcomes, public.training_assignments, public.v21_purchase_order_allocations, public.v21_purchase_plan_allocations, public.v22_supplier_confirmation_lines, public.v22_supplier_confirmations, public.v22_supplier_logistics_metrics, public.v22_supply_exceptions, public.v23_demand_signals, public.v23_recovery_recommendations, public.v23_shipment_risk_snapshots, public.v23_supplier_commitments, public.v23_supplier_replenishment_lines, public.v23_supplier_replenishment_runs, public.v23_supplier_risk_snapshots, public.v26_position_results, public.v26_scenarios, public.v26_simulation_runs, public.v27_decision_candidates, public.v27_decision_runs, public.v28_agent_actions, public.v28_agent_runs, public.v28_autonomy_policies, public.v28_outcome_measurements, public.waste_records FROM anon;
REVOKE INSERT ON TABLE public.network_ledger_forensic_events FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.exchange_rates, public.financial_accounts, public.financial_ledger_entries, public.fta_audit_log, public.gcc_cross_border_escrow, public.gcc_cross_border_manifest_lines, public.gcc_cross_border_manifests, public.gcc_cross_border_pod, public.gcc_customs_events, public.gcc_customs_hs_tariffs, public.gcc_data_residency_lineage, public.gcc_ledger_exchange_rates, public.gcc_supported_currencies, public.gcc_tax_business_access, public.gcc_tax_ledger, public.multi_tenant_escrow_controls, public.network_dispatch_financial_clearances, public.network_evidence_oracles, public.network_evidence_verification_events, public.network_financial_divergences, public.network_financial_finality_gates, public.network_financial_finality_requirements, public.network_financial_repair_events, public.network_financial_repairs, public.network_invoice_lines, public.network_invoices, public.network_ledger_continuity_checks, public.network_ledger_forensic_certifications, public.network_ledger_repair_lines, public.network_liquidity_reservations, public.network_liquidity_sources, public.network_oracle_evidence, public.network_reconciliation_runs, public.network_settlement_route_legs, public.network_settlement_routes, public.network_settlement_routing_events, public.settlement_batch_lines, public.settlement_batches, public.users, public.v22_financial_forensic_ledger, public.v22_logistics_financial_valuations, public.v22_logistics_milestones, public.v22_logistics_shipments FROM authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public.network_audit_stream, public.network_contract_lines, public.network_contract_negotiation_lines, public.network_contract_negotiations, public.network_contract_signatures, public.network_contracts, public.network_dispatches_disputes, public.network_key_rotation_logs, public.network_order_dispatch_lines, public.network_order_dispatches, public.network_organization_verifications, public.network_organizations, public.network_sales_order_lines, public.network_sales_orders, public.network_tenant_keys, public.routing_deficit_bypasses, public.routing_execution_logs, public.stock_transfer_batch_lines, public.stock_transfer_recommendations, public.v22_supplier_confirmation_lines, public.v22_supplier_confirmations, public.v22_supplier_logistics_metrics, public.v22_supply_exceptions, public.v23_demand_signals, public.v23_recovery_recommendations, public.v23_shipment_risk_snapshots, public.v23_supplier_commitments, public.v23_supplier_replenishment_lines, public.v23_supplier_replenishment_runs, public.v23_supplier_risk_snapshots, public.v26_position_results, public.v26_scenarios, public.v26_simulation_runs, public.v27_decision_candidates, public.v27_decision_runs, public.v28_agent_actions, public.v28_agent_runs, public.v28_autonomy_policies, public.v28_outcome_measurements, public.v29_learning_outcomes, public.v29_policy_candidates, public.v29_policy_evaluations FROM authenticated;
REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLE public._nabuuma_deployment_bootstrap, public.gcc_invoice_sequences, public.network_break_glass_authorizations, public.network_break_glass_events, public.network_founder_identity_registry, public.network_ip_provenance_events, public.network_platform_ip_asset_versions, public.network_platform_ip_assets, public.network_root_key_registry, public.network_signing_workflow_signatures, public.network_signing_workflows FROM authenticated;
REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public.assessments, public.business_members, public.businesses, public.certifications, public.courses, public.demand_forecasts, public.goods_receipt_lines, public.goods_receipts, public.ingredient_batches, public.ingredient_daily_consumption, public.ingredient_prices, public.ingredients, public.inventory_batches, public.inventory_execution_failures, public.inventory_execution_receipts, public.inventory_ledger_entries, public.inventory_ledger_transactions, public.inventory_locations, public.inventory_movements, public.inventory_service_targets, public.inventory_transfer_lines, public.inventory_transfers, public.locations, public.products, public.purchase_order_lines, public.purchase_orders, public.purchase_plan_lines, public.purchase_plans, public.qc_checks, public.recipe_ingredients, public.recipe_versions, public.service_events, public.staff_profiles, public.stock_transfer_lines, public.stock_transfers, public.subscriptions, public.supplier_execution_metrics, public.supplier_ingredient_terms, public.supplier_recommendations, public.suppliers, public.supply_automation_events, public.supply_automation_runs, public.supply_recovery_actions, public.supply_recovery_approvals, public.supply_recovery_outcomes, public.training_assignments, public.v21_purchase_order_allocations, public.v21_purchase_plan_allocations, public.waste_records FROM authenticated;
REVOKE UPDATE, DELETE ON TABLE public.network_dispatched_receipts, public.supplier_delivery_commitments, public.supplier_logistics_events FROM authenticated;
REVOKE UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public.audit_logs FROM authenticated;
REVOKE INSERT ON TABLE public.network_ledger_forensic_events FROM service_role;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.exchange_rates, public.fta_audit_log, public.gcc_cross_border_escrow, public.gcc_cross_border_manifest_lines, public.gcc_cross_border_manifests, public.gcc_cross_border_pod, public.gcc_customs_events, public.gcc_data_residency_lineage, public.gcc_tax_ledger, public.network_evidence_oracles, public.network_evidence_verification_events, public.network_financial_divergences, public.network_financial_finality_gates, public.network_financial_finality_requirements, public.network_financial_repair_events, public.network_financial_repairs, public.network_ledger_continuity_checks, public.network_ledger_forensic_certifications, public.network_ledger_repair_lines, public.network_liquidity_reservations, public.network_liquidity_sources, public.network_oracle_evidence, public.network_reconciliation_runs, public.network_settlement_route_legs, public.network_settlement_routes, public.network_settlement_routing_events FROM service_role;
REVOKE UPDATE, DELETE ON TABLE public.gcc_customs_hs_tariffs FROM service_role;

-- V3.15.7 must precede this migration. Keep audit_logs client access limited
-- to the explicit authenticated read/append contract.
DO $verify_client_acl$
DECLARE
    t text;
    service_only text[] := ARRAY[
        'gcc_invoice_sequences',
        'network_break_glass_authorizations',
        'network_break_glass_events',
        'network_founder_identity_registry',
        'network_ip_provenance_events',
        'network_platform_ip_asset_versions',
        'network_platform_ip_assets',
        'network_root_key_registry',
        'network_signing_workflow_signatures',
        'network_signing_workflows',
        '_nabuuma_deployment_bootstrap'
    ];
BEGIN
    FOR t IN SELECT unnest(service_only) LOOP
        IF has_table_privilege('anon', format('public.%I', t), 'SELECT')
           OR has_table_privilege('anon', format('public.%I', t), 'INSERT')
           OR has_table_privilege('anon', format('public.%I', t), 'UPDATE')
           OR has_table_privilege('anon', format('public.%I', t), 'DELETE')
           OR has_table_privilege('authenticated', format('public.%I', t), 'SELECT')
           OR has_table_privilege('authenticated', format('public.%I', t), 'INSERT')
           OR has_table_privilege('authenticated', format('public.%I', t), 'UPDATE')
           OR has_table_privilege('authenticated', format('public.%I', t), 'DELETE') THEN
            RAISE EXCEPTION 'Client ACL remains on service-only table %', t;
        END IF;
    END LOOP;

    IF has_table_privilege('anon','public.users','SELECT')
       OR has_table_privilege('anon','public.stock_transfer_recommendations','SELECT')
       OR NOT has_table_privilege('authenticated','public.users','SELECT')
       OR NOT has_table_privilege('authenticated','public.stock_transfer_recommendations','SELECT')
       OR has_table_privilege('authenticated','public.stock_transfer_recommendations','INSERT')
       OR has_table_privilege('authenticated','public.stock_transfer_recommendations','UPDATE')
       OR has_table_privilege('authenticated','public.stock_transfer_recommendations','DELETE') THEN
        RAISE EXCEPTION 'Users/recommendations client ACL does not match the intended boundary';
    END IF;

    IF has_table_privilege('anon','public.audit_logs','SELECT')
       OR has_table_privilege('anon','public.audit_logs','INSERT')
       OR has_table_privilege('authenticated','public.audit_logs','UPDATE')
       OR has_table_privilege('authenticated','public.audit_logs','DELETE') THEN
        RAISE EXCEPTION 'audit_logs client ACL does not match V3.15.7';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
          AND (
              has_table_privilege('anon', c.oid, 'TRUNCATE')
              OR has_table_privilege('authenticated', c.oid, 'TRUNCATE')
              OR has_table_privilege('anon', c.oid, 'MAINTAIN')
              OR has_table_privilege('authenticated', c.oid, 'MAINTAIN')
              OR has_table_privilege('anon', c.oid, 'REFERENCES')
              OR has_table_privilege('authenticated', c.oid, 'REFERENCES')
              OR has_table_privilege('anon', c.oid, 'TRIGGER')
              OR has_table_privilege('authenticated', c.oid, 'TRIGGER')
          )
    ) THEN
        RAISE EXCEPTION 'Non-DML client privilege remains on a public base table';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_default_acl AS d
        CROSS JOIN LATERAL pg_catalog.aclexplode(d.defaclacl) AS a
        WHERE d.defaclobjtype = 'r'
          AND d.defaclnamespace = 'public'::regnamespace
          AND d.defaclrole = 'postgres'::regrole
          AND a.grantee IN (0, 'anon'::regrole, 'authenticated'::regrole)
          AND a.privilege_type IN ('TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN')
    ) THEN
        RAISE EXCEPTION 'Unsafe non-DML client privileges remain in postgres public default ACLs';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_default_acl AS d
        CROSS JOIN LATERAL pg_catalog.aclexplode(d.defaclacl) AS a
        WHERE d.defaclrole = 'postgres'::regrole
          AND (
            (d.defaclnamespace = 'public'::regnamespace
             AND d.defaclobjtype IN ('r', 'S', 'f')
             AND a.grantee IN ('anon'::regrole, 'authenticated'::regrole, 'service_role'::regrole))
            OR (d.defaclobjtype = 'f' AND d.defaclnamespace = 0 AND a.grantee = 0)
          )
    ) THEN
        RAISE EXCEPTION 'API-role or PUBLIC execution grants remain in postgres defaults';
    END IF;
END;
$verify_client_acl$;

COMMIT;
