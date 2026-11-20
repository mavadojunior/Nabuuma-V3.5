# Production schema parity report

**Snapshot date:** 2026-11-14
**Supabase project:** `mzfkamgfvxypakfkjdfs`
**Repository:** `mavadojunior/Nabuuma-V3.5`
**Branch:** `fix/v3.15.6-rls-migration`
**Production access:** read-only catalog queries; no production DDL or data changes.

## Result

**Structural reconciliation: PASS with one intentional FK correction. Production ACL parity: FAIL pending deployment; platform default ACL remains outside migration-role authority.**

The 69 production migration records match the recovered repository manifest. The 69 migrations were replayed in order on disposable PostgreSQL 17.11. The updated `20261114043000` migration was then applied against a clone carrying the production FK state. Migration `20261114043200` was subsequently applied to harden the two legacy SECURITY DEFINER trigger functions. All structural objects matched the reconstructed migration model except one deliberate correction: production's `recipe_versions_id_fkey` is replaced with the original `recipe_versions_product_id_fkey` relationship. The table is empty and the orphan check returned zero.

| Catalog area | Production | Reconstructed | Structural differences |
|---|---:|---:|---:|
| Schemas | 2 | 2 | 0 |
| Relations (tables, views, sequences, etc.) | 176 | 176 | 0 |
| Columns | 1,685 | 1,685 | 0 |
| Constraints | 922 | 922 | 1 intentional FK correction |
| Indexes | 393 | 393 | 0 |
| Functions | 144 | 144 | 0 |
| Triggers | 50 | 50 | 0 |
| RLS policies | 182 | 182 | 0 |
| Types | 171 | 171 | 0 |
| Event triggers | 1 | 1 | 0 |

After the migration, the comparison found no other differences in column definitions, constraint definitions, index definitions, function source hashes, function security/configuration attributes, trigger definitions, policy expressions/roles, enum labels, or event-trigger definitions. The one FK correction restores the versioned recipe model defined in the recovered migration history: `recipe_versions.product_id` references `products.id`, while `products.active_recipe_version_id` references `recipe_versions.id`.

## Recovered production drift

The 69-row migration ledger did not account for all current production objects. The reconciliation migration now restores these five objects:

1. `nabuuma.custom_access_token_hook(jsonb)` — private authentication hook.
2. `public.publish_recipe(uuid)` — service-role-only RPC.
3. All 12 public views — security-invoker, non-updatable views with API-role `SELECT` only after migration 431.
4. `public.financial_ledger_transaction_balance_ct` — deferred constraint trigger.
5. `public.network_ledger_forensic_events_no_truncate` — statement-level truncate guard.

The reconciliation restores 12 production indexes and three constraints, removes the redundant composite unique key and duplicate clearance index, reconciles 27 policy definitions, and restores 19 production function definitions/configurations. It corrects two function EXECUTE ACLs and removes `TRUNCATE` from `service_role` on the immutable forensic event table. The deferred `financial_ledger_transaction_balance_ct` trigger is recreated and verified; it is not removed.

The recipe FK correction is deliberate. Production had `recipe_versions.id -> products.id`, which conflicts with the repository's versioned model and the `(product_id, version_number)` uniqueness rule. The production table currently has zero rows, and the migration checks for orphan `product_id` values before replacing that FK. The composite unique key on `financial_ledger_entries(transaction_id,id)` is redundant with its primary key on `id`; the non-unique transaction lookup index remains. The removed clearance index duplicates the existing `network_dispatch_financial_clearances_settlement_idx`. The three affected financial/recipe tables currently have zero rows.

## Effective privilege comparison

The privilege snapshot is a separate result. A disposable replay was initialized with Supabase-style client grants, then the 69 recovered migrations and the pending security migrations were applied. The initial comparison before the full ACL reconciliation showed 207 relation/role rows and 686 production-only privilege bits. The updated `20261114043100` migration now contains explicit revocations for the complete current drift.

| ACL scope | Production-only differences against the hardened replay |
|---|---:|
| Schema privileges | 0 |
| Relation privileges | 364 relation/role rows |
| Function EXECUTE privileges | 0 |

The 364 rows contain 1,652 production-only privilege bits: 162 rows for `anon`, 162 for `authenticated`, and 40 for `service_role`. This total combines the original 329 relation/role drift rows with 35 additional view-role rows; the existing `view_v29_learning_control_tower`/`anon` row is already in the original set. Migration 431 retains 16 grouped table-ACL revocation statements and adds a dynamic block that preserves `SELECT` while removing every other API-role privilege from all 12 public views.

The original 207-row baseline is retained in `PRODUCTION_ACL_DRIFT_2026-11-14.csv`. The current 364-row comparison is in `PRODUCTION_ACL_DRIFT_AFTER_HARDENING_2026-11-14.csv`; it now includes all 12 public views and records `SELECT` as the intended retained API privilege.

Production has 151 public base tables and two private `nabuuma` base tables. All 151 public base tables have RLS enabled; one has FORCE RLS. All 12 public views use `security_invoker=true`. Even so, production grants `TRUNCATE`, `MAINTAIN`, `REFERENCES`, and `TRIGGER` to `anon` on 87 public base tables and to `authenticated` on 92. RLS does not block `TRUNCATE`.

The 69-row history explicitly revokes or narrows privileges on service-only, immutable, financial, customs, settlement, logistics, and tenant-scoped tables. Production has since accumulated grants that exceed those recorded boundaries. The new ACL matrix restores the effective rights from the recovered history rather than assuming every production grant is intentional.

Two local security migrations now address this:

- `20261019000000_v3_15_7_least_privilege_rls.sql` restricts `audit_logs` to authenticated `SELECT`/`INSERT` and service-role operations.
- `20261114043100_restore_client_acl_boundaries.sql` removes non-DML client privileges across all public base tables, restores the named table boundaries from migration history, reconciles 364 relation/role rows and 1,652 excess privilege bits, and applies `SELECT`-only API grants to all 12 public views. It changes default privileges for objects created by `postgres` only. It deliberately does not alter `supabase_admin` defaults: production confirms `postgres` is neither a member of `supabase_admin` nor a superuser, so that statement would fail under the actual migration role.

The migrations have passed local replay tests. The ACL matrix was tested against a local clone seeded with all 364 production-only relation/role rows (1,652 privilege bits). After applying the updated migration, the final snapshot matched the intended reconciled ACL model: 8 schema-privilege rows, 704 relation-privilege rows, and 576 function-privilege rows. Reapplying the migration also passed.

Production's `supabase_admin` public-schema default ACL remains a material platform-owned risk. For future objects created by that role, API roles receive all eight table privileges, `SELECT`/`UPDATE`/`USAGE` on sequences, and `EXECUTE` on functions. The production `postgres` role is neither a member of `supabase_admin` nor a superuser, so it cannot alter those defaults. This is not remediated by migration 431. The production database has not been changed.

## Validation performed

- All 69 recovered production migrations replayed successfully on disposable PostgreSQL 17.11.
- The expanded reconciliation migration applied successfully on a clean replay and passed its catalog assertions.
- The updated structural migration was applied to a replay clone with production's `recipe_versions_id_fkey` state. It replaced that FK with `recipe_versions_product_id_fkey`, rejected unexpected definitions/orphan rows, and passed the remaining catalog checks.
- The current production ACL snapshot was compared with the post-V3.15.7 replay: 364 production-only relation/role rows and 1,652 excess privilege bits were identified, including 35 additional view-role rows; migration 431 now includes the dynamic view ACL reconciliation.
- V3.15.7 migration plus its isolated fixture/assertion suite passed: authenticated SELECT/INSERT, no anon access, cross-tenant read/write rejection, trusted SECURITY DEFINER trigger writes, and retained service-role operations.
- V3.15.7 followed by `20261114043100_restore_client_acl_boundaries.sql` passed on the full reconstructed schema. Its assertions confirmed zero client non-DML privileges across all 151 public base tables and restored service-only/restricted-table ACLs. The 364-row ACL delta is covered by the grouped table revocations and dynamic view ACL block; local full-schema assertions pass.
- `git diff --check` passed.

**Local replay limitation:** the local OS does not have the `pg_cron` extension package. The one `CREATE EXTENSION IF NOT EXISTS pg_cron` statement was omitted only in the disposable replay; no recovered migration references cron objects. `pgcrypto` and `pgtap` were installed in `extensions`. The harness supplied minimal `auth.users`, `auth.uid()`, and `auth.role()` stubs. This was a PostgreSQL migration replay, not a full Supabase Docker stack reset.

## Pending work and deployment boundary

- `20261019000000_v3_15_7_least_privilege_rls.sql`, `20261114043000_reconcile_production_schema_drift.sql`, `20261114043100_restore_client_acl_boundaries.sql`, and `20261114043200_harden_legacy_trigger_search_paths.sql` remain local drafts; none has been inserted into production migration history.
- The original 207-row ACL CSV is retained as the baseline. The current 364-row / 1,652-bit comparison is recorded in `PRODUCTION_ACL_DRIFT_AFTER_HARDENING_2026-11-14.csv` and drives the expanded ACL migration.
- Migration 432 narrows both legacy SECURITY DEFINER trigger functions to `search_path=pg_catalog`; its assertions passed against the disposable full-schema replay. The hosted full-stack replay job has been added but has not yet run.
- The `supabase_admin` default ACL remains platform-owned and outside the privileges of the production `postgres` migration role. Do not claim future-object default ACL parity until Supabase confirms an authorized remediation path.
- No production migration was applied. No production schema, ACL, policy, or data was changed. Nothing was committed or pushed.
