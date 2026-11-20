# Production Migration History Reconciliation

**Review date:** 2026-11-14

> Latest verification: see [Production Schema Parity Report](PRODUCTION_SCHEMA_PARITY_REPORT_2026-11-14.md) and [current ACL drift detail](PRODUCTION_ACL_DRIFT_AFTER_HARDENING_2026-11-14.csv). Structural reconciliation passes with one intentional recipe-version FK correction; relation ACL remediation is pending deployment and the platform-owned `supabase_admin` default ACL remains unresolved.
**Project:** `mzfkamgfvxypakfkjdfs`
**Repository:** `mavadojunior/Nabuuma-V3.5`
**Branch inspected:** `fix/v3.15.6-rls-migration`
**Supabase CLI:** 2.122.0

## Result

**Verified: 69 of 69 production migrations matched.**

The read-only production migration ledger contains **69** applied records. The recovered manifest matches all 69. There are no remote-only versions. Four local-only migrations remain pending:

- `20261019000000_v3_15_7_least_privilege_rls.sql`, `20261114043000_reconcile_production_schema_drift.sql`, `20261114043100_restore_client_acl_boundaries.sql`, and `20261114043200_harden_legacy_trigger_search_paths.sql`.

The latest production migration is `20260921041538`.


V3.15.7 is the pending `audit_logs` least-privilege change. The second local-only migration reconciles production catalog drift; the third restores current client ACL boundaries and `postgres` default privileges; the fourth narrows the two legacy SECURITY DEFINER trigger functions to `search_path=pg_catalog`. All four remain unapplied in production.

## Recovery provenance

The production table `supabase_migrations.schema_migrations` stores `version`, `name`, `statements`, and `rollback`. All 69 applied records had exactly one stored SQL statement; all rollback arrays were empty.

The 69 active migration files were reconstructed from the stored `statements[1]` values and named using the production `version` and `name` fields. For every file:

- The SQL text length matched PostgreSQL's `length(statements[1])` value.
- The file name matched the production version and migration name.
- A credential-pattern scan found no private keys, JWTs, AWS keys, API-key patterns, credential-bearing PostgreSQL URLs, or role-password clauses.
- A SHA-256 and byte-length record was written to `docs/PRODUCTION_MIGRATION_RECOVERY_MANIFEST_2026-11-14.csv`.

**Important provenance distinction:** these files reproduce the SQL statements stored by the production migration runner. They are recovered executed SQL, not a byte-for-byte restoration of the original Git files. No rollback scripts could be recovered because the production rollback arrays are empty. Do not reformat or edit the recovered files without a new migration review.

The integrity gate `scripts/check-migration-history.sh` verifies the 69 file names, byte lengths, and SHA-256 hashes against the manifest. It passed locally and is now part of the database migration workflow.

## Superseded local migration draft

`20260916023400_v3_15_6_rls_rejection_policies.sql` was present in Git but absent from the production ledger. Its 13-table rejection-policy work is superseded by the production-applied `20260921041538` reconciliation migration. Keeping the older timestamp active would cause an unapplied migration older than the latest production migration.

The committed Git version was therefore preserved under `supabase/archive/20260916023400_v3_15_6_rls_rejection_policies.sql` and removed from the active migration directory. A second, ignored `.bak` draft that targeted only `public.audit_logs` was also moved to `supabase/archive/20260916023400_v3_15_6_audit_logs_restrictive_draft.sql`. Both are retained for provenance and must not be replayed. The archive README explains their status.

## Pending V3.15.7 migration

`20261019000000_v3_15_7_least_privilege_rls.sql` is the pending security migration; the separate production catalog reconciliation is recorded in the linked parity report. It addresses the current production `public.audit_logs` ACL/RLS gap:

- Revokes client table and column privileges from `PUBLIC`, `anon`, and `authenticated`.
- Restores only `SELECT` and `INSERT` to `authenticated`.
- Retains `service_role` operational grants.
- Enables RLS but deliberately does not force it. Production SECURITY DEFINER trigger writers owned by `postgres` write to `audit_logs`; FORCE RLS would subject those trusted writes to the client INSERT guard.
- Removes the legacy permissive false `reject_all_public_access` policy if present; the restrictive tenant guards provide the actual row-access boundary.
- Installs restrictive tenant-membership and write-identity guards, plus restrictive UPDATE/DELETE denials.

The migration remains a draft. No production `db push` was run.

## Trusted audit-trigger dependency

Production has three `SECURITY DEFINER` trigger functions owned by `postgres` that insert into `public.audit_logs`:

- `audit_purchase_order_row_change_v1` — attached to purchase orders, purchase-order lines, goods receipts, and goods-receipt lines. It writes `user_id = auth.uid()`.
- `v21_audit_allocation_insert` — attached to two allocation tables. It writes `created_by` rather than `user_id`.
- `v22_audit_milestone` — attached to logistics milestones. It writes `user_id = coalesce(new.created_by, auth.uid())`.

The latter two do not consistently satisfy the proposed client INSERT policy's `user_id = auth.uid()` condition. With `FORCE ROW LEVEL SECURITY`, these owner-executed trigger writes would be subject to that restrictive policy and could fail. V3.15.7 therefore keeps RLS enabled but explicitly sets `NO FORCE ROW LEVEL SECURITY`. Client roles still face the table ACL and RLS policies; `service_role` retains its `BYPASSRLS` behavior. A regression test verifies that a trusted SECURITY DEFINER trigger can write an audit row with a NULL `user_id` while cross-tenant clients remain blocked. Migration 432 separately hardens both trigger functions' search paths.

Migration `20261114043200_harden_legacy_trigger_search_paths.sql` now sets both functions to `search_path=pg_catalog`. The function bodies, ownership, grants, and trigger attachments are unchanged; the new assertion passed against the reconstructed schema.

## Current production `audit_logs` state (read-only verification)

- RLS is enabled; `FORCE ROW LEVEL SECURITY` is disabled.
- `anon` and `authenticated` each have effective `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `REFERENCES`, `TRIGGER`, and PostgreSQL 17 `MAINTAIN` privileges.
- `service_role` also has all eight privileges, as expected for its operational role.
- Current policies are four permissive policies: `audit_logs_select`, `audit_write`, `audit_no_update`, and `audit_no_delete`.
- There is no current `reject_all_public_access` policy and no V3.15.7 restrictive guard policy. The recovered `20260921041538` migration creates a **permissive false** policy with that name. Its absence in the current catalog indicates later schema drift or a manual removal; it is not itself a restrictive deny policy.
- The `public.is_member(uuid)` helper exists as `SECURITY DEFINER`, with an empty `search_path` and schema-qualified references.

RLS does not restrict `TRUNCATE`; false UPDATE/DELETE policies do not revoke table privileges. The current ACL therefore needs a separate privilege correction.

## Validation completed

- `supabase migration list --linked` before the final two additions: **69 matched, 0 remote-only**. The current local tree has four pending migrations.
- `scripts/check-migration-history.sh`: passed; all 69 recovered hashes and sizes matched.
- Full 69-migration replay on disposable PostgreSQL 17.11: passed. The local `pg_cron` extension package was unavailable, so its extension-creation statement was omitted only in the disposable replay; no recovered migration references cron objects.
- Updated `20261114043000` reconciliation migration: passed against a full-replay clone with the production recipe FK state. It replaces the production-only `recipe_versions.id -> products.id` FK with the migration-history `recipe_versions.product_id -> products.id` FK after a zero-orphan check; the table currently has zero rows. All other structural catalog checks passed.
- Effective schema and function privileges matched. The baseline relation ACL comparison found 207 relation/role rows with 686 production-only privilege bits. The follow-on ACL hardening migration was tested locally and removes client TRUNCATE/MAINTAIN/REFERENCES/TRIGGER grants from all public base tables, then restores the explicit table boundaries in the migration history. See the parity report and CSV.
- Isolated V3.15.7 fixture, migration, and assertions: passed. The test verified authenticated SELECT/INSERT, no anon access, cross-tenant rejection, trusted SECURITY DEFINER trigger writes, and service-role operations.
- The migration workflow includes the PostgreSQL 17.6 ACL-reconciliation fixture and a new full Supabase-stack replay job. The full replay job has been authored but has not yet run on GitHub Actions.
- `git diff --check`: passed.

A full `supabase db reset` was not run locally because Docker is unavailable in this UserLAnd environment. The 430/431 structural and ACL migrations were validated on the disposable full-schema replay database. Migration 432 and its structural/search-path assertions passed against that replay; the ACL assertions and all-12-view `SELECT`-only checks also passed there. The new full Supabase-stack CI job remains unexecuted. The platform-owned `supabase_admin` default ACL remains open before production deployment.

## Critical production history entries

| Timestamp | Recorded name |
|---|---|
| `20260917070958` | `nabuuma_v3156_service_table_explicit_rls_boundaries` |
| `20260917071021` | `nabuuma_v3157_bootstrap_explicit_rls_boundary` |
| `20260917142431` | `nabuuma_v35_logistics_rpc_and_rls_hardening` |
| `20260917142502` | `nabuuma_v35_harden_internal_logistics_definer` |
| `20260917145030` | `20260917180100_v36_search_path_probe` |
| `20260917145115` | `20260917180300_v36_gcc_valuation_forensic_core` |
| `20260917145127` | `20260917180400_v36_self_verification` |
| `20260917185509` | `20260917190000_v36_runtime_integration_hardening` |
| `20260921041538` | `nabuuma_v3156_service_table_explicit_rls_boundaries_reconcile` |

These production entries are distinct from the local `20260916023400` draft. Their executed SQL is now recovered from the production ledger and present in the active migration directory. The older Library logistics bundle is supporting context, not the authoritative source for these production migrations.

## Full remote migration timestamp ledger

| # | Remote timestamp | UTC applied time |
|---:|---|---|
| 1 | `20260906035952` | 2026-09-06 03:59:52 |
| 2 | `20260906035956` | 2026-09-06 03:59:56 |
| 3 | `20260906040014` | 2026-09-06 04:00:14 |
| 4 | `20260906040031` | 2026-09-06 04:00:31 |
| 5 | `20260906040052` | 2026-09-06 04:00:52 |
| 6 | `20260906040110` | 2026-09-06 04:01:10 |
| 7 | `20260906040154` | 2026-09-06 04:01:54 |
| 8 | `20260906040719` | 2026-09-06 04:07:19 |
| 9 | `20260906040949` | 2026-09-06 04:09:49 |
| 10 | `20260906041121` | 2026-09-06 04:11:21 |
| 11 | `20260906041222` | 2026-09-06 04:12:22 |
| 12 | `20260906041259` | 2026-09-06 04:12:59 |
| 13 | `20260906041340` | 2026-09-06 04:13:40 |
| 14 | `20260906041357` | 2026-09-06 04:13:57 |
| 15 | `20260906041538` | 2026-09-06 04:15:38 |
| 16 | `20260906041751` | 2026-09-06 04:17:51 |
| 17 | `20260906041839` | 2026-09-06 04:18:39 |
| 18 | `20260906042006` | 2026-09-06 04:20:06 |
| 19 | `20260906042319` | 2026-09-06 04:23:19 |
| 20 | `20260906051838` | 2026-09-06 05:18:38 |
| 21 | `20260906051915` | 2026-09-06 05:19:15 |
| 22 | `20260906051927` | 2026-09-06 05:19:27 |
| 23 | `20260906052004` | 2026-09-06 05:20:04 |
| 24 | `20260906053514` | 2026-09-06 05:35:14 |
| 25 | `20260906054839` | 2026-09-06 05:48:39 |
| 26 | `20260906054851` | 2026-09-06 05:48:51 |
| 27 | `20260906055759` | 2026-09-06 05:57:59 |
| 28 | `20260906071752` | 2026-09-06 07:17:52 |
| 29 | `20260906080703` | 2026-09-06 08:07:03 |
| 30 | `20260906090332` | 2026-09-06 09:03:32 |
| 31 | `20260906090430` | 2026-09-06 09:04:30 |
| 32 | `20260906090515` | 2026-09-06 09:05:15 |
| 33 | `20260906091252` | 2026-09-06 09:12:52 |
| 34 | `20260906091648` | 2026-09-06 09:16:48 |
| 35 | `20260906185629` | 2026-09-06 18:56:29 |
| 36 | `20260906214042` | 2026-09-06 21:40:42 |
| 37 | `20260906214117` | 2026-09-06 21:41:17 |
| 38 | `20260906214218` | 2026-09-06 21:42:18 |
| 39 | `20260906215700` | 2026-09-06 21:57:00 |
| 40 | `20260906215738` | 2026-09-06 21:57:38 |
| 41 | `20260907090909` | 2026-09-07 09:09:09 |
| 42 | `20260907115841` | 2026-09-07 11:58:41 |
| 43 | `20260910110522` | 2026-09-10 11:05:22 |
| 44 | `20260910111645` | 2026-09-10 11:16:45 |
| 45 | `20260915223303` | 2026-09-15 22:33:03 |
| 46 | `20260915223614` | 2026-09-15 22:36:14 |
| 47 | `20260915233009` | 2026-09-15 23:30:09 |
| 48 | `20260915233452` | 2026-09-15 23:34:52 |
| 49 | `20260915233914` | 2026-09-15 23:39:14 |
| 50 | `20260915233921` | 2026-09-15 23:39:21 |
| 51 | `20260915233952` | 2026-09-15 23:39:52 |
| 52 | `20260915234634` | 2026-09-15 23:46:34 |
| 53 | `20260915234948` | 2026-09-15 23:49:48 |
| 54 | `20260915235002` | 2026-09-15 23:50:02 |
| 55 | `20260915235244` | 2026-09-15 23:52:44 |
| 56 | `20260916000728` | 2026-09-16 00:07:28 |
| 57 | `20260916002948` | 2026-09-16 00:29:48 |
| 58 | `20260916004440` | 2026-09-16 00:44:40 |
| 59 | `20260916004509` | 2026-09-16 00:45:09 |
| 60 | `20260916004547` | 2026-09-16 00:45:47 |
| 61 | `20260917070958` | 2026-09-17 07:09:58 |
| 62 | `20260917071021` | 2026-09-17 07:10:21 |
| 63 | `20260917142431` | 2026-09-17 14:24:31 |
| 64 | `20260917142502` | 2026-09-17 14:25:02 |
| 65 | `20260917145030` | 2026-09-17 14:50:30 |
| 66 | `20260917145115` | 2026-09-17 14:51:15 |
| 67 | `20260917145127` | 2026-09-17 14:51:27 |
| 68 | `20260917185509` | 2026-09-17 18:55:09 |
| 69 | `20260921041538` | 2026-09-21 04:15:38 |

## Supporting Library artifacts

The Library contains related logistics deployment, introspection, and test SQL files. They are not a complete archive of the 69 migrations. The older 35-axis logistics SQL test also uses a `v22_finalize_cross_border_pod` helper signature that does not match the current production signature `(uuid, uuid, timestamptz, text)`, so it was not copied into the active test suite without correction.

## Remaining blockers

1. Review the 207 effective relation-privilege differences against Supabase platform defaults and the intended least-privilege model. Do not widen repository grants just to force raw ACL equality.
2. Review and approve all four pending local migrations (`20261019000000`, `20261114043000`, `20261114043100`, and `20261114043200`) before deployment.
3. Re-run the full replay on a complete disposable Supabase stack when Docker or an equivalent environment is available.
4. The current branch is four commits behind `origin/main`. Merge or rebase after reviewing the local changes; this was not done to avoid disturbing the existing staged and untracked work.
5. This checkout still lacks the application source directories and build/typecheck/lint scripts. Application verification and deployment are unavailable.
6. Supabase Auth leaked-password protection remains disabled; this is a separate project Auth setting.

## Production change boundary

- No production migration was applied.
- No production migration history row was inserted, deleted, or repaired.
- No production schema, grants, policies, or data were modified.
- No deployment was run.
- The staged `package.json` and other pre-existing user changes were preserved.
