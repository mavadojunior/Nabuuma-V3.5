# Production migration deployment review

**Original review date:** 2026-11-14
**Release-gate update:** 2026-11-17
**Project:** `mzfkamgfvxypakfkjdfs`
**Repository:** `mavadojunior/Nabuuma-V3.5`
**Reviewed branch:** `enforce/release-readiness-v1`
**Reviewed commit:** `4ba31f9c20b0ba386ac922c4536319586f71dd32`

## Decision

**Do not deploy yet.** The migration chain and hosted CI are validated, but independent review of the latest commit, production operational checks, and an authorized release decision remain outstanding.

1. The platform-owned `supabase_admin` default ACL cannot be changed by the production `postgres` migration role. Current public objects were audited; future objects created by `supabase_admin` remain a platform-owned privilege risk requiring a separate decision.
2. The full Supabase-stack replay completed successfully on GitHub Actions run [43996903591](https://github.com/mavadojunior/Nabuuma-V3.5/actions/runs/43996903591). All four database jobs passed, including settlement execution and rollback. Microsoft Defender run [43996903571](https://github.com/mavadojunior/Nabuuma-V3.5/actions/runs/43996903571) also passed.
3. PR #4 remains open and unmerged. CodeRabbit paused automatic review at `3fea9dbe`; the latest commit `4ba31f9c` was not covered by that review. A fresh review is required before merge.

The two legacy SECURITY DEFINER trigger functions are now hardened by `20261114043200_harden_legacy_trigger_search_paths.sql`. Local assertions verified both retain SECURITY DEFINER and use `search_path=pg_catalog`.

## Deployment order

The production migration ledger contains 69 applied migrations, latest `20260921041538`. The following four remain local-only and must be applied in timestamp order:

1. `20261019000000_v3_15_7_least_privilege_rls.sql`
2. `20261114043000_reconcile_production_schema_drift.sql`
3. `20261114043100_restore_client_acl_boundaries.sql`
4. `20261114043200_harden_legacy_trigger_search_paths.sql`

Do not reorder them. V3.15.7 establishes the `audit_logs` restrictive guards. The structural reconciliation follows it. The ACL migration restores the effective table and view privileges recorded by the recovered history. The final migration hardens the two legacy trigger-function search paths.

## Migration review

### `20261019000000_v3_15_7_least_privilege_rls.sql`

- Narrows `audit_logs` to authenticated `SELECT`/`INSERT` and trusted service-role operations.
- Enables RLS without forcing it. This is required because existing SECURITY DEFINER audit triggers owned by `postgres` write rows that do not always carry `user_id = auth.uid()`.
- Adds restrictive tenant and write-identity guards plus restrictive UPDATE/DELETE denials.
- Its isolated fixture verifies authenticated access, anon denial, cross-tenant denial, and trusted trigger writes.
- No row data is rewritten.

### `20261114043000_reconcile_production_schema_drift.sql`

- Reconciles the structural drift not represented by the 69 applied migration records: relations, indexes, constraints, policies, function definitions/configuration, trigger definitions and function ACLs.
- Runs in a transaction with `lock_timeout = 10s` and `statement_timeout = 60s`.
- No top-level `INSERT`, `UPDATE`, `DELETE`, or `TRUNCATE` is executed. DML found in the file is inside stored function bodies and is not run by the migration.
- Recreates and verifies `financial_ledger_transaction_balance_ct`; it is retained, not removed.
- Replaces the production-only `recipe_versions.id -> products.id` FK with the migration-history relationship `recipe_versions.product_id -> products.id`. The live table currently has zero rows, and the migration aborts if `product_id` contains an orphan. This preserves the versioned recipe model.
- Removes the redundant unique key on `financial_ledger_entries(transaction_id,id)` because `id` is already the primary key. The non-unique `financial_ledger_entries_transaction_idx` remains.
- Removes `dispatch_financial_clearance_batch_idx` only when its definition is the known duplicate and the replacement `network_dispatch_financial_clearances_settlement_idx` exists.
- The recipe FK and index removals now have definition preconditions. Unexpected definitions fail the transaction rather than being silently dropped.
- The financial ledger, recipe-version and dispatch-clearance tables returned zero live rows in the production checks. All targeted index tables had zero estimated rows and small relation sizes.

### `20261114043100_restore_client_acl_boundaries.sql`

- Removes non-DML client privileges across public base tables; RLS does not restrict `TRUNCATE`.
- Restores explicit service-only, read-only and read/write table boundaries from the recovered history.
- Contains 16 grouped table-ACL revocation statements for the original drift plus a dynamic view ACL block. The combined comparison covers 364 relation/role rows and 1,652 excess privilege bits: 162 `anon`, 162 `authenticated`, and 40 `service_role` rows.
- The table matrix is based on the read-only production ACL snapshot compared with the 69-migration replay plus V3.15.7. All 12 public views are additionally reconciled to API-role `SELECT` only.
- Tested against a local clone seeded with all observed production-only grants. The final schema/relation/function ACL snapshot was verified against the intended reconciled model: 8 schema rows, 704 relation rows, 576 function rows. Reapplication passed.
- A PostgreSQL 17.6 fixture job checks the explicit ACL drift assertions, exercises the generic view ACL assertions, and runs the migration twice. The full-schema replay separately verifies all 12 public views.
- The migration changes `postgres` default privileges only. It intentionally does not attempt to alter `supabase_admin` defaults: production `postgres` is not a member of that role and is not a superuser. The attempted statement would fail in production.

### `20261114043200_harden_legacy_trigger_search_paths.sql`

- Alters only the function configuration for `public.v21_audit_allocation_insert()` and `public.v22_audit_milestone()`.
- Sets both SECURITY DEFINER trigger functions to `search_path=pg_catalog`. Their application relations and `auth.uid()` calls are schema-qualified; built-in functions resolve from `pg_catalog`.
- Does not replace function bodies, change ownership, alter EXECUTE grants, or modify trigger attachments.
- Applied successfully to the disposable full-schema replay database. The new assertion verifies both functions remain SECURITY DEFINER and have exactly the expected search-path setting.


## Residual risks

- Production `supabase_admin` has public-schema defaults that grant API roles all eight table privileges, `SELECT`/`UPDATE`/`USAGE` on sequences, and `EXECUTE` on functions. Production `postgres` is neither a member of `supabase_admin` nor a superuser, so migration 431 cannot change those defaults. Current table/view ACLs are reconciled; future objects created by `supabase_admin` remain a platform-owned risk.
- The two legacy SECURITY DEFINER trigger functions have been hardened by migration 432; the successful hosted full-replay run verified this on a clean Supabase stack.
- All 12 production public views are security-invoker and report zero automatically updatable columns. Migration 430 gives `recipe_costs` `SELECT` only; migration 431 now applies `SELECT`-only grants to every public view for `anon`, `authenticated`, and `service_role`. The ACL assertion checks all seven non-SELECT privilege types across every public view.
- CI has focused V3.15.7 and 431 jobs plus a new full Supabase-stack replay job covering the complete migration chain. The full replay job is authored but not yet executed on GitHub.

## Rollback and operational risk

- Each pending migration is transactional. A statement error, failed precondition, lock timeout, or assertion failure rolls back that migration's transaction.
- The production migration ledger has empty rollback arrays. There is no recovered automated rollback SQL.
- After a migration commits, treat remediation as forward-only. Prepare a compensating migration rather than attempting `db reset` or manually reversing function/policy/constraint changes.
- `20261114043000` replaces functions, policies, triggers and indexes and acquires DDL locks. Apply during a controlled low-traffic window. Its 10-second lock timeout intentionally fails fast if a conflicting transaction is active.
- Take a managed backup/snapshot and save fresh schema/ACL fingerprints immediately before deployment. Confirm the 69/69 migration ledger again, then apply one migration at a time and rerun catalog/ACL assertions after each commit.
- Do not deploy while another operator or automated pipeline is changing schema or grants.

## CI and validation status

- 69 recovered production migrations replayed on disposable PostgreSQL 17.11; the optional `pg_cron` extension creation was omitted only in the local harness because the package is unavailable. No recovered migration references cron objects.
- Updated 430 applied to a replay clone carrying the production recipe FK state; the corrected FK and structural assertions passed.
- Updated 431 applied to the reconstructed full-schema database; 704 relation ACL rows were present and the all-view ACL assertions passed.
- The PostgreSQL 17.6 ACL fixture and idempotency run passed locally; the full-schema test also verified all 12 public views have `SELECT` only for API roles. Migration 432 and structural assertions passed on the reconstructed full-schema database; the ACL assertions also passed there. Hosted full-replay run 43996903591 passed.
- Full Supabase Docker reset was not run because Docker is unavailable in the UserLAnd environment. The replay used minimal Auth stubs.

## Commit preparation

The working tree contains the recovered 69-migration history, manifest, archive move, scripts/configuration, workflow changes, documentation, and pending migrations. It also contains an already-staged `package.json` change that is unrelated to the database milestone.

Do not combine these into one opaque commit. Recommended split:

1. **Recovery baseline:** 69 recovered migrations, recovery manifest, integrity-check script, Supabase config, archive move and associated provenance documentation.
2. **Schema/security milestone:** V3.15.7, structural reconciliation, ACL reconciliation, ACL fixture/assertions, workflow job and review reports.

No commit or push has been made. The unrelated staged `package.json` entry remains separate from the database milestone.
