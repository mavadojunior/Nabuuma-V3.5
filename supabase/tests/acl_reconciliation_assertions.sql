\set ON_ERROR_STOP on
-- Assert every production-only privilege bit is absent after migration 431.
DO $acl_assertions$
DECLARE
  r record;
  p text;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('anon', '_nabuuma_deployment_bootstrap', 'select,insert,update,delete'),
      ('authenticated', '_nabuuma_deployment_bootstrap', 'select,insert,update,delete'),
      ('anon', 'assessments', 'truncate,references,trigger,maintain'),
      ('authenticated', 'assessments', 'truncate,references,trigger,maintain'),
      ('anon', 'audit_logs', 'select,insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'audit_logs', 'update,delete,truncate,references,trigger,maintain'),
      ('anon', 'business_members', 'truncate,references,trigger,maintain'),
      ('authenticated', 'business_members', 'truncate,references,trigger,maintain'),
      ('anon', 'businesses', 'truncate,references,trigger,maintain'),
      ('authenticated', 'businesses', 'truncate,references,trigger,maintain'),
      ('anon', 'certifications', 'truncate,references,trigger,maintain'),
      ('authenticated', 'certifications', 'truncate,references,trigger,maintain'),
      ('anon', 'courses', 'truncate,references,trigger,maintain'),
      ('authenticated', 'courses', 'truncate,references,trigger,maintain'),
      ('anon', 'demand_forecasts', 'truncate,references,trigger,maintain'),
      ('authenticated', 'demand_forecasts', 'truncate,references,trigger,maintain'),
      ('anon', 'exchange_rates', 'select,insert,update,delete'),
      ('authenticated', 'exchange_rates', 'insert,update,delete'),
      ('service_role', 'exchange_rates', 'insert,update,delete'),
      ('anon', 'financial_accounts', 'select,insert,update,delete'),
      ('authenticated', 'financial_accounts', 'insert,update,delete'),
      ('anon', 'financial_ledger_entries', 'select,insert,update,delete'),
      ('authenticated', 'financial_ledger_entries', 'insert,update,delete'),
      ('anon', 'fta_audit_log', 'select,insert,update,delete'),
      ('authenticated', 'fta_audit_log', 'insert,update,delete'),
      ('service_role', 'fta_audit_log', 'insert,update,delete'),
      ('anon', 'gcc_cross_border_escrow', 'select,insert,update,delete'),
      ('authenticated', 'gcc_cross_border_escrow', 'insert,update,delete'),
      ('service_role', 'gcc_cross_border_escrow', 'insert,update,delete'),
      ('anon', 'gcc_cross_border_manifest_lines', 'select,insert,update,delete'),
      ('authenticated', 'gcc_cross_border_manifest_lines', 'insert,update,delete'),
      ('service_role', 'gcc_cross_border_manifest_lines', 'insert,update,delete'),
      ('anon', 'gcc_cross_border_manifests', 'select,insert,update,delete'),
      ('authenticated', 'gcc_cross_border_manifests', 'insert,update,delete'),
      ('service_role', 'gcc_cross_border_manifests', 'insert,update,delete'),
      ('anon', 'gcc_cross_border_pod', 'select,insert,update,delete'),
      ('authenticated', 'gcc_cross_border_pod', 'insert,update,delete'),
      ('service_role', 'gcc_cross_border_pod', 'insert,update,delete'),
      ('anon', 'gcc_customs_events', 'select,insert,update,delete'),
      ('authenticated', 'gcc_customs_events', 'insert,update,delete'),
      ('service_role', 'gcc_customs_events', 'insert,update,delete'),
      ('anon', 'gcc_customs_hs_tariffs', 'select,insert,update,delete'),
      ('authenticated', 'gcc_customs_hs_tariffs', 'insert,update,delete'),
      ('service_role', 'gcc_customs_hs_tariffs', 'update,delete'),
      ('anon', 'gcc_data_residency_lineage', 'select,insert,update,delete'),
      ('authenticated', 'gcc_data_residency_lineage', 'insert,update,delete'),
      ('service_role', 'gcc_data_residency_lineage', 'insert,update,delete'),
      ('anon', 'gcc_invoice_sequences', 'select,insert,update,delete'),
      ('authenticated', 'gcc_invoice_sequences', 'select,insert,update,delete'),
      ('anon', 'gcc_ledger_exchange_rates', 'select,insert,update,delete'),
      ('authenticated', 'gcc_ledger_exchange_rates', 'insert,update,delete'),
      ('anon', 'gcc_supported_currencies', 'select,insert,update,delete'),
      ('authenticated', 'gcc_supported_currencies', 'insert,update,delete'),
      ('anon', 'gcc_tax_business_access', 'select,insert,update,delete'),
      ('authenticated', 'gcc_tax_business_access', 'insert,update,delete'),
      ('anon', 'gcc_tax_ledger', 'select,insert,update,delete'),
      ('authenticated', 'gcc_tax_ledger', 'insert,update,delete'),
      ('service_role', 'gcc_tax_ledger', 'insert,update,delete'),
      ('anon', 'goods_receipt_lines', 'truncate,references,trigger,maintain'),
      ('authenticated', 'goods_receipt_lines', 'truncate,references,trigger,maintain'),
      ('anon', 'goods_receipts', 'truncate,references,trigger,maintain'),
      ('authenticated', 'goods_receipts', 'truncate,references,trigger,maintain'),
      ('anon', 'ingredient_batches', 'truncate,references,trigger,maintain'),
      ('authenticated', 'ingredient_batches', 'truncate,references,trigger,maintain'),
      ('anon', 'ingredient_daily_consumption', 'truncate,references,trigger,maintain'),
      ('authenticated', 'ingredient_daily_consumption', 'truncate,references,trigger,maintain'),
      ('anon', 'ingredient_prices', 'truncate,references,trigger,maintain'),
      ('authenticated', 'ingredient_prices', 'truncate,references,trigger,maintain'),
      ('anon', 'ingredients', 'truncate,references,trigger,maintain'),
      ('authenticated', 'ingredients', 'truncate,references,trigger,maintain'),
      ('anon', 'inventory_batches', 'truncate,references,trigger,maintain'),
      ('authenticated', 'inventory_batches', 'truncate,references,trigger,maintain'),
      ('anon', 'inventory_execution_failures', 'truncate,references,trigger,maintain'),
      ('authenticated', 'inventory_execution_failures', 'truncate,references,trigger,maintain'),
      ('anon', 'inventory_execution_receipts', 'truncate,references,trigger,maintain'),
      ('authenticated', 'inventory_execution_receipts', 'truncate,references,trigger,maintain'),
      ('anon', 'inventory_ledger_entries', 'truncate,references,trigger,maintain'),
      ('authenticated', 'inventory_ledger_entries', 'truncate,references,trigger,maintain'),
      ('anon', 'inventory_ledger_transactions', 'truncate,references,trigger,maintain'),
      ('authenticated', 'inventory_ledger_transactions', 'truncate,references,trigger,maintain'),
      ('anon', 'inventory_locations', 'truncate,references,trigger,maintain'),
      ('authenticated', 'inventory_locations', 'truncate,references,trigger,maintain'),
      ('anon', 'inventory_movements', 'truncate,references,trigger,maintain'),
      ('authenticated', 'inventory_movements', 'truncate,references,trigger,maintain'),
      ('anon', 'inventory_service_targets', 'truncate,references,trigger,maintain'),
      ('authenticated', 'inventory_service_targets', 'truncate,references,trigger,maintain'),
      ('anon', 'inventory_transfer_lines', 'truncate,references,trigger,maintain'),
      ('authenticated', 'inventory_transfer_lines', 'truncate,references,trigger,maintain'),
      ('anon', 'inventory_transfers', 'truncate,references,trigger,maintain'),
      ('authenticated', 'inventory_transfers', 'truncate,references,trigger,maintain'),
      ('anon', 'locations', 'truncate,references,trigger,maintain'),
      ('authenticated', 'locations', 'truncate,references,trigger,maintain'),
      ('anon', 'multi_tenant_escrow_controls', 'select,insert,update,delete'),
      ('authenticated', 'multi_tenant_escrow_controls', 'insert,update,delete'),
      ('anon', 'network_audit_stream', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_audit_stream', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_break_glass_authorizations', 'select,insert,update,delete'),
      ('authenticated', 'network_break_glass_authorizations', 'select,insert,update,delete'),
      ('anon', 'network_break_glass_events', 'select,insert,update,delete'),
      ('authenticated', 'network_break_glass_events', 'select,insert,update,delete'),
      ('anon', 'network_contract_lines', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_contract_lines', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_contract_negotiation_lines', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_contract_negotiation_lines', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_contract_negotiations', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_contract_negotiations', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_contract_signatures', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_contract_signatures', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_contracts', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_contracts', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_dispatch_financial_clearances', 'select,insert,update,delete'),
      ('authenticated', 'network_dispatch_financial_clearances', 'insert,update,delete'),
      ('anon', 'network_dispatched_receipts', 'select,insert,update,delete'),
      ('authenticated', 'network_dispatched_receipts', 'update,delete'),
      ('anon', 'network_dispatches_disputes', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_dispatches_disputes', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_evidence_oracles', 'select,insert,update,delete'),
      ('authenticated', 'network_evidence_oracles', 'insert,update,delete'),
      ('service_role', 'network_evidence_oracles', 'insert,update,delete'),
      ('anon', 'network_evidence_verification_events', 'select,insert,update,delete'),
      ('authenticated', 'network_evidence_verification_events', 'insert,update,delete'),
      ('service_role', 'network_evidence_verification_events', 'insert,update,delete'),
      ('anon', 'network_financial_divergences', 'select,insert,update,delete'),
      ('authenticated', 'network_financial_divergences', 'insert,update,delete'),
      ('service_role', 'network_financial_divergences', 'insert,update,delete'),
      ('anon', 'network_financial_finality_gates', 'select,insert,update,delete'),
      ('authenticated', 'network_financial_finality_gates', 'insert,update,delete'),
      ('service_role', 'network_financial_finality_gates', 'insert,update,delete'),
      ('anon', 'network_financial_finality_requirements', 'select,insert,update,delete'),
      ('authenticated', 'network_financial_finality_requirements', 'insert,update,delete'),
      ('service_role', 'network_financial_finality_requirements', 'insert,update,delete'),
      ('anon', 'network_financial_repair_events', 'select,insert,update,delete'),
      ('authenticated', 'network_financial_repair_events', 'insert,update,delete'),
      ('service_role', 'network_financial_repair_events', 'insert,update,delete'),
      ('anon', 'network_financial_repairs', 'select,insert,update,delete'),
      ('authenticated', 'network_financial_repairs', 'insert,update,delete'),
      ('service_role', 'network_financial_repairs', 'insert,update,delete'),
      ('anon', 'network_founder_identity_registry', 'select,insert,update,delete'),
      ('authenticated', 'network_founder_identity_registry', 'select,insert,update,delete'),
      ('anon', 'network_invoice_lines', 'select,insert,update,delete'),
      ('authenticated', 'network_invoice_lines', 'insert,update,delete'),
      ('anon', 'network_invoices', 'select,insert,update,delete'),
      ('authenticated', 'network_invoices', 'insert,update,delete'),
      ('anon', 'network_ip_provenance_events', 'select,insert,update,delete'),
      ('authenticated', 'network_ip_provenance_events', 'select,insert,update,delete'),
      ('anon', 'network_key_rotation_logs', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_key_rotation_logs', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_ledger_continuity_checks', 'select,insert,update,delete'),
      ('authenticated', 'network_ledger_continuity_checks', 'insert,update,delete'),
      ('service_role', 'network_ledger_continuity_checks', 'insert,update,delete'),
      ('anon', 'network_ledger_forensic_certifications', 'select,insert,update,delete'),
      ('authenticated', 'network_ledger_forensic_certifications', 'insert,update,delete'),
      ('service_role', 'network_ledger_forensic_certifications', 'insert,update,delete'),
      ('anon', 'network_ledger_forensic_events', 'select,insert'),
      ('authenticated', 'network_ledger_forensic_events', 'insert'),
      ('service_role', 'network_ledger_forensic_events', 'insert'),
      ('anon', 'network_ledger_repair_lines', 'select,insert,update,delete'),
      ('authenticated', 'network_ledger_repair_lines', 'insert,update,delete'),
      ('service_role', 'network_ledger_repair_lines', 'insert,update,delete'),
      ('anon', 'network_liquidity_reservations', 'select,insert,update,delete'),
      ('authenticated', 'network_liquidity_reservations', 'insert,update,delete'),
      ('service_role', 'network_liquidity_reservations', 'insert,update,delete'),
      ('anon', 'network_liquidity_sources', 'select,insert,update,delete'),
      ('authenticated', 'network_liquidity_sources', 'insert,update,delete'),
      ('service_role', 'network_liquidity_sources', 'insert,update,delete'),
      ('anon', 'network_oracle_evidence', 'select,insert,update,delete'),
      ('authenticated', 'network_oracle_evidence', 'insert,update,delete'),
      ('service_role', 'network_oracle_evidence', 'insert,update,delete'),
      ('anon', 'network_order_dispatch_lines', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_order_dispatch_lines', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_order_dispatches', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_order_dispatches', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_organization_verifications', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_organization_verifications', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_organizations', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_organizations', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_platform_ip_asset_versions', 'select,insert,update,delete'),
      ('authenticated', 'network_platform_ip_asset_versions', 'select,insert,update,delete'),
      ('anon', 'network_platform_ip_assets', 'select,insert,update,delete'),
      ('authenticated', 'network_platform_ip_assets', 'select,insert,update,delete'),
      ('anon', 'network_reconciliation_runs', 'select,insert,update,delete'),
      ('authenticated', 'network_reconciliation_runs', 'insert,update,delete'),
      ('service_role', 'network_reconciliation_runs', 'insert,update,delete'),
      ('anon', 'network_root_key_registry', 'select,insert,update,delete'),
      ('authenticated', 'network_root_key_registry', 'select,insert,update,delete'),
      ('anon', 'network_sales_order_lines', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_sales_order_lines', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_sales_orders', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_sales_orders', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'network_settlement_route_legs', 'select,insert,update,delete'),
      ('authenticated', 'network_settlement_route_legs', 'insert,update,delete'),
      ('service_role', 'network_settlement_route_legs', 'insert,update,delete'),
      ('anon', 'network_settlement_routes', 'select,insert,update,delete'),
      ('authenticated', 'network_settlement_routes', 'insert,update,delete'),
      ('service_role', 'network_settlement_routes', 'insert,update,delete'),
      ('anon', 'network_settlement_routing_events', 'select,insert,update,delete'),
      ('authenticated', 'network_settlement_routing_events', 'insert,update,delete'),
      ('service_role', 'network_settlement_routing_events', 'insert,update,delete'),
      ('anon', 'network_signing_workflow_signatures', 'select,insert,update,delete'),
      ('authenticated', 'network_signing_workflow_signatures', 'select,insert,update,delete'),
      ('anon', 'network_signing_workflows', 'select,insert,update,delete'),
      ('authenticated', 'network_signing_workflows', 'select,insert,update,delete'),
      ('anon', 'network_tenant_keys', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('authenticated', 'network_tenant_keys', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'products', 'truncate,references,trigger,maintain'),
      ('authenticated', 'products', 'truncate,references,trigger,maintain'),
      ('anon', 'purchase_order_lines', 'truncate,references,trigger,maintain'),
      ('authenticated', 'purchase_order_lines', 'truncate,references,trigger,maintain'),
      ('anon', 'purchase_orders', 'truncate,references,trigger,maintain'),
      ('authenticated', 'purchase_orders', 'truncate,references,trigger,maintain'),
      ('anon', 'purchase_plan_lines', 'truncate,references,trigger,maintain'),
      ('authenticated', 'purchase_plan_lines', 'truncate,references,trigger,maintain'),
      ('anon', 'purchase_plans', 'truncate,references,trigger,maintain'),
      ('authenticated', 'purchase_plans', 'truncate,references,trigger,maintain'),
      ('anon', 'qc_checks', 'truncate,references,trigger,maintain'),
      ('authenticated', 'qc_checks', 'truncate,references,trigger,maintain'),
      ('anon', 'recipe_ingredients', 'truncate,references,trigger,maintain'),
      ('authenticated', 'recipe_ingredients', 'truncate,references,trigger,maintain'),
      ('anon', 'recipe_versions', 'truncate,references,trigger,maintain'),
      ('authenticated', 'recipe_versions', 'truncate,references,trigger,maintain'),
      ('anon', 'routing_deficit_bypasses', 'truncate,references,trigger,maintain'),
      ('authenticated', 'routing_deficit_bypasses', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'routing_execution_logs', 'truncate,references,trigger,maintain'),
      ('authenticated', 'routing_execution_logs', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'service_events', 'truncate,references,trigger,maintain'),
      ('authenticated', 'service_events', 'truncate,references,trigger,maintain'),
      ('anon', 'settlement_batch_lines', 'select,insert,update,delete'),
      ('authenticated', 'settlement_batch_lines', 'insert,update,delete'),
      ('anon', 'settlement_batches', 'select,insert,update,delete'),
      ('authenticated', 'settlement_batches', 'insert,update,delete'),
      ('anon', 'staff_profiles', 'truncate,references,trigger,maintain'),
      ('authenticated', 'staff_profiles', 'truncate,references,trigger,maintain'),
      ('anon', 'stock_transfer_batch_lines', 'select,insert,update,delete'),
      ('authenticated', 'stock_transfer_batch_lines', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'stock_transfer_lines', 'truncate,references,trigger,maintain'),
      ('authenticated', 'stock_transfer_lines', 'truncate,references,trigger,maintain'),
      ('anon', 'stock_transfer_recommendations', 'select,insert,update,delete'),
      ('authenticated', 'stock_transfer_recommendations', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'stock_transfers', 'truncate,references,trigger,maintain'),
      ('authenticated', 'stock_transfers', 'truncate,references,trigger,maintain'),
      ('anon', 'subscriptions', 'truncate,references,trigger,maintain'),
      ('authenticated', 'subscriptions', 'truncate,references,trigger,maintain'),
      ('anon', 'supplier_delivery_commitments', 'select,insert,update,delete'),
      ('authenticated', 'supplier_delivery_commitments', 'update,delete'),
      ('anon', 'supplier_execution_metrics', 'truncate,references,trigger,maintain'),
      ('authenticated', 'supplier_execution_metrics', 'truncate,references,trigger,maintain'),
      ('anon', 'supplier_ingredient_terms', 'truncate,references,trigger,maintain'),
      ('authenticated', 'supplier_ingredient_terms', 'truncate,references,trigger,maintain'),
      ('anon', 'supplier_logistics_events', 'select,insert,update,delete'),
      ('authenticated', 'supplier_logistics_events', 'update,delete'),
      ('anon', 'supplier_recommendations', 'truncate,references,trigger,maintain'),
      ('authenticated', 'supplier_recommendations', 'truncate,references,trigger,maintain'),
      ('anon', 'suppliers', 'truncate,references,trigger,maintain'),
      ('authenticated', 'suppliers', 'truncate,references,trigger,maintain'),
      ('anon', 'supply_automation_events', 'truncate,references,trigger,maintain'),
      ('authenticated', 'supply_automation_events', 'truncate,references,trigger,maintain'),
      ('anon', 'supply_automation_runs', 'truncate,references,trigger,maintain'),
      ('authenticated', 'supply_automation_runs', 'truncate,references,trigger,maintain'),
      ('anon', 'supply_recovery_actions', 'truncate,references,trigger,maintain'),
      ('authenticated', 'supply_recovery_actions', 'truncate,references,trigger,maintain'),
      ('anon', 'supply_recovery_approvals', 'truncate,references,trigger,maintain'),
      ('authenticated', 'supply_recovery_approvals', 'truncate,references,trigger,maintain'),
      ('anon', 'supply_recovery_outcomes', 'truncate,references,trigger,maintain'),
      ('authenticated', 'supply_recovery_outcomes', 'truncate,references,trigger,maintain'),
      ('anon', 'training_assignments', 'truncate,references,trigger,maintain'),
      ('authenticated', 'training_assignments', 'truncate,references,trigger,maintain'),
      ('anon', 'users', 'select,insert,update,delete'),
      ('authenticated', 'users', 'insert,update,delete'),
      ('anon', 'v21_purchase_order_allocations', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v21_purchase_order_allocations', 'truncate,references,trigger,maintain'),
      ('anon', 'v21_purchase_plan_allocations', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v21_purchase_plan_allocations', 'truncate,references,trigger,maintain'),
      ('anon', 'v22_financial_forensic_ledger', 'select,insert,update,delete'),
      ('authenticated', 'v22_financial_forensic_ledger', 'insert,update,delete'),
      ('anon', 'v22_logistics_financial_valuations', 'select,insert,update,delete'),
      ('authenticated', 'v22_logistics_financial_valuations', 'insert,update,delete'),
      ('anon', 'v22_logistics_milestones', 'select,insert,update,delete'),
      ('authenticated', 'v22_logistics_milestones', 'insert,update,delete'),
      ('anon', 'v22_logistics_shipments', 'select,insert,update,delete'),
      ('authenticated', 'v22_logistics_shipments', 'insert,update,delete'),
      ('anon', 'v22_supplier_confirmation_lines', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v22_supplier_confirmation_lines', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v22_supplier_confirmations', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v22_supplier_confirmations', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v22_supplier_logistics_metrics', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v22_supplier_logistics_metrics', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v22_supply_exceptions', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v22_supply_exceptions', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v23_demand_signals', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v23_demand_signals', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v23_recovery_recommendations', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v23_recovery_recommendations', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v23_shipment_risk_snapshots', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v23_shipment_risk_snapshots', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v23_supplier_commitments', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v23_supplier_commitments', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v23_supplier_replenishment_lines', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v23_supplier_replenishment_lines', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v23_supplier_replenishment_runs', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v23_supplier_replenishment_runs', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v23_supplier_risk_snapshots', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v23_supplier_risk_snapshots', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v26_position_results', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v26_position_results', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v26_scenarios', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v26_scenarios', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v26_simulation_runs', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v26_simulation_runs', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v27_decision_candidates', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v27_decision_candidates', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v27_decision_runs', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v27_decision_runs', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v28_agent_actions', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v28_agent_actions', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v28_agent_runs', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v28_agent_runs', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v28_autonomy_policies', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v28_autonomy_policies', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v28_outcome_measurements', 'truncate,references,trigger,maintain'),
      ('authenticated', 'v28_outcome_measurements', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v29_learning_outcomes', 'select,insert,update,delete'),
      ('authenticated', 'v29_learning_outcomes', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v29_policy_candidates', 'select,insert,update,delete'),
      ('authenticated', 'v29_policy_candidates', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'v29_policy_evaluations', 'select,insert,update,delete'),
      ('authenticated', 'v29_policy_evaluations', 'insert,update,delete,truncate,references,trigger,maintain'),
      ('anon', 'view_v29_learning_control_tower', 'insert,update,delete'),
      ('anon', 'waste_records', 'truncate,references,trigger,maintain'),
      ('authenticated', 'waste_records', 'truncate,references,trigger,maintain')
    ) AS expected(role_name, relation_name, privileges)
  LOOP
    FOREACH p IN ARRAY string_to_array(r.privileges, ',') LOOP
      IF pg_catalog.has_table_privilege(r.role_name, format('public.%I', r.relation_name), upper(p)) THEN
        RAISE EXCEPTION 'Unexpected % privilege for % on public.%', upper(p), r.role_name, r.relation_name;
      END IF;
    END LOOP;
  END LOOP;
END
$acl_assertions$;

-- Every public view remains readable by API roles but carries no write or
-- relation-maintenance privileges. This covers all current and future views.
DO $view_acl_assertions$
DECLARE
  v record;
  role_name text;
  privilege_name text;
BEGIN
  FOR v IN
    SELECT c.oid, c.relname
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'v'
  LOOP
    FOREACH role_name IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
      IF NOT pg_catalog.has_table_privilege(role_name, v.oid, 'SELECT') THEN
        RAISE EXCEPTION 'Missing SELECT on public.% for %', v.relname, role_name;
      END IF;
      FOREACH privilege_name IN ARRAY ARRAY[
        'INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'
      ] LOOP
        IF pg_catalog.has_table_privilege(role_name, v.oid, privilege_name) THEN
          RAISE EXCEPTION 'Unexpected % on public.% for %', privilege_name, v.relname, role_name;
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;
END
$view_acl_assertions$;

DO $positive_assertions$ BEGIN
  IF NOT has_table_privilege('authenticated','public.audit_logs','SELECT') OR NOT has_table_privilege('authenticated','public.audit_logs','INSERT') THEN RAISE EXCEPTION 'authenticated audit_logs SELECT/INSERT missing'; END IF;
  IF has_table_privilege('anon','public.audit_logs','SELECT') OR has_table_privilege('anon','public.audit_logs','INSERT') THEN RAISE EXCEPTION 'anon can access audit_logs'; END IF;
  IF NOT has_table_privilege('authenticated','public.stock_transfer_batch_lines','SELECT') OR has_table_privilege('authenticated','public.stock_transfer_batch_lines','INSERT') OR has_table_privilege('authenticated','public.stock_transfer_batch_lines','UPDATE') OR has_table_privilege('authenticated','public.stock_transfer_batch_lines','DELETE') THEN RAISE EXCEPTION 'stock_transfer_batch_lines client boundary incorrect'; END IF;
  IF NOT has_table_privilege('authenticated','public.stock_transfer_recommendations','SELECT') OR has_table_privilege('authenticated','public.stock_transfer_recommendations','INSERT') OR has_table_privilege('authenticated','public.stock_transfer_recommendations','UPDATE') OR has_table_privilege('authenticated','public.stock_transfer_recommendations','DELETE') THEN RAISE EXCEPTION 'stock_transfer_recommendations client boundary incorrect'; END IF;
  IF NOT has_table_privilege('authenticated','public.network_ledger_repair_lines','SELECT') OR has_table_privilege('service_role','public.network_ledger_repair_lines','INSERT') OR has_table_privilege('service_role','public.network_ledger_repair_lines','UPDATE') OR has_table_privilege('service_role','public.network_ledger_repair_lines','DELETE') THEN RAISE EXCEPTION 'network_ledger_repair_lines append-only boundary incorrect'; END IF;
END $positive_assertions$;

-- PUBLIC DML grants are inherited by every API role. The migration must
-- remove the grant itself, not merely mask it with role-specific revokes.
DO $public_dml_assertions$
DECLARE
  role_name text;
  privilege_name text;
BEGIN
  FOREACH role_name IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    FOREACH privilege_name IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE'] LOOP
      IF pg_catalog.has_table_privilege(
        role_name,
        'public.acl_public_dml_probe',
        privilege_name
      ) THEN
        RAISE EXCEPTION 'PUBLIC % privilege still inherited by % on acl_public_dml_probe',
          privilege_name, role_name;
      END IF;
    END LOOP;
  END LOOP;
END
$public_dml_assertions$;


-- Exercise actual defaults by creating disposable objects as the migration
-- owner. Existing function ACLs are intentionally outside this test's scope.
DROP TABLE IF EXISTS public.__acl_default_table_probe;
DROP SEQUENCE IF EXISTS public.__acl_default_sequence_probe;
DROP FUNCTION IF EXISTS public.__acl_default_function_probe();
CREATE TABLE public.__acl_default_table_probe (id bigint);
CREATE SEQUENCE public.__acl_default_sequence_probe;
CREATE FUNCTION public.__acl_default_function_probe() RETURNS integer
LANGUAGE sql AS $$ SELECT 1 $$;

DO $default_acl_runtime_assertions$
DECLARE
  role_name text;
BEGIN
  FOREACH role_name IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF has_table_privilege(role_name, 'public.__acl_default_table_probe', 'SELECT')
       OR has_table_privilege(role_name, 'public.__acl_default_table_probe', 'INSERT')
       OR has_table_privilege(role_name, 'public.__acl_default_table_probe', 'UPDATE')
       OR has_table_privilege(role_name, 'public.__acl_default_table_probe', 'DELETE')
       OR has_table_privilege(role_name, 'public.__acl_default_table_probe', 'TRUNCATE')
       OR has_table_privilege(role_name, 'public.__acl_default_table_probe', 'REFERENCES')
       OR has_table_privilege(role_name, 'public.__acl_default_table_probe', 'TRIGGER')
       OR has_table_privilege(role_name, 'public.__acl_default_table_probe', 'MAINTAIN')
       OR has_sequence_privilege(role_name, 'public.__acl_default_sequence_probe', 'USAGE')
       OR has_sequence_privilege(role_name, 'public.__acl_default_sequence_probe', 'SELECT')
       OR has_sequence_privilege(role_name, 'public.__acl_default_sequence_probe', 'UPDATE')
       OR has_function_privilege(role_name, 'public.__acl_default_function_probe()', 'EXECUTE') THEN
      RAISE EXCEPTION 'New public objects inherited an API-role grant for %', role_name;
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
    WHERE p.oid = 'public.__acl_default_function_probe()'::regprocedure
      AND a.grantee = 0
      AND a.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'New postgres function inherited PUBLIC EXECUTE';
  END IF;
END
$default_acl_runtime_assertions$;

-- The existing policy helper grant remains intact, and explicit grants remain
-- the required path for future RPCs and policy helper functions.
DO $existing_policy_helper_assertion$
BEGIN
  IF NOT has_function_privilege('authenticated', 'public.is_member(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Existing RLS helper is_member(uuid) lost authenticated EXECUTE';
  END IF;
END
$existing_policy_helper_assertion$;

GRANT EXECUTE ON FUNCTION public.__acl_default_function_probe() TO authenticated, service_role;
DO $explicit_default_grant_assertion$
BEGIN
  IF NOT has_function_privilege('service_role', 'public.__acl_default_function_probe()', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.__acl_default_function_probe()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.__acl_default_function_probe()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Explicit API-role function grants did not preserve the intended boundary';
  END IF;
END
$explicit_default_grant_assertion$;

DROP FUNCTION public.__acl_default_function_probe();
DROP SEQUENCE public.__acl_default_sequence_probe;
DROP TABLE public.__acl_default_table_probe;
