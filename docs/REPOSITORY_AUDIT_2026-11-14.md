# Nabuuma V3.5 — Repository and Production Security Audit

**Review date:** 2026-11-14
**Repository:** mavadojunior/Nabuuma-V3.5
**Local branch inspected:** fix/v3.15.6-rls-migration
**Supabase project:** mzfkamgfvxypakfkjdfs
**Production PostgreSQL:** 17.6

## Executive findings

The repository is currently a database/security work area, not a complete application checkout. Before this review, its tracked tree contained seven files and one SQL migration. The 69 production migration statements have now been reconstructed into local SQL files. There is still no app/, lib/, middleware.ts, types/, or application test suite. The package.json contains only the aasvg dependency and defines no build, lint, typecheck, or test scripts.

The production database has 69 recorded migrations, latest version 20260921041538. All 69 executed SQL statements have been reconstructed from the production ledger, and the linked CLI now reports 69 matching local/remote timestamps, zero remote-only entries, and one pending local-only V3.15.7 migration. **Do not run supabase db push until a full clean migration replay has been validated and the pending V3.15.7 migration is approved.**

## Migration history reconciliation

The 69 applied SQL statements were recovered from the production migration ledger and now match all 69 remote timestamps. One local-only migration remains pending: `20261019000000_v3_15_7_least_privilege_rls.sql`. The old `20260916023400` draft is archived. The exact timestamp ledger, recovery provenance, hashes, and validation results are in [MIGRATION_HISTORY_RECONCILIATION_2026-11-14.md](MIGRATION_HISTORY_RECONCILIATION_2026-11-14.md). No remote history repair was performed.

## Production findings

### public.audit_logs

Catalog and privilege inspection returned:

- RLS enabled.
- FORCE ROW LEVEL SECURITY disabled.
- Owner: postgres.
- Existing policies:
  - audit_logs_select: permissive SELECT, is_member(business_id).
  - audit_write: permissive INSERT, membership plus user_id = auth.uid().
  - audit_no_update: permissive UPDATE policy with USING (false).
  - audit_no_delete: permissive DELETE policy with USING (false).
- anon and authenticated both have effective table privileges including SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, and PostgreSQL 17 MAINTAIN.
- service_role has those table privileges and has BYPASSRLS.

The key gap is TRUNCATE: PostgreSQL does not apply row-level security policies to TRUNCATE. False UPDATE and DELETE policies do not remove that table privilege. The existing ACL therefore needs correction independently of its row policies.

The public.is_member(uuid) helper exists. It is SECURITY DEFINER, has an empty search_path, and schema-qualifies public.business_members and auth.uid(). No change to that function was required by this review.

Three other SECURITY DEFINER trigger functions write to `audit_logs`: `audit_purchase_order_row_change_v1`, `v21_audit_allocation_insert`, and `v22_audit_milestone`. They are owned by `postgres`. Migration `20261114043200_harden_legacy_trigger_search_paths.sql` now sets the latter two to `search_path=pg_catalog`; their function bodies, ownership, grants, and trigger attachments are unchanged. Their differing `user_id` behavior means `FORCE ROW LEVEL SECURITY` would block some trusted trigger inserts, so the pending V3.15.7 migration explicitly leaves FORCE disabled while retaining client ACL and RLS enforcement.

Three other SECURITY DEFINER trigger functions write to `audit_logs`: `audit_purchase_order_row_change_v1`, `v21_audit_allocation_insert`, and `v22_audit_milestone`. They are owned by `postgres`. Migration `20261114043200_harden_legacy_trigger_search_paths.sql` now sets the latter two to `search_path=pg_catalog`; their function bodies, ownership, grants, and trigger attachments are unchanged. Their differing `user_id` behavior means `FORCE ROW LEVEL SECURITY` would block some trusted trigger inserts, so the pending V3.15.7 migration explicitly leaves FORCE disabled while retaining client ACL and RLS enforcement.

### Other production findings

- The nabuuma schema has no USAGE privilege for anon or authenticated.
- The two advisor findings for nabuuma.organisation_memberships and nabuuma.organisations report RLS enabled with no policies. Neither role has schema usage or table SELECT/INSERT privileges in the inspected state. Treat these as informational until the schema is intentionally exposed.
- Supabase Auth leaked-password protection is disabled. This is a project Auth setting, not a repository migration.

## Changes made in this working tree

### Recovered production migration history

The 69 applied production migrations were reconstructed from `supabase_migrations.schema_migrations.statements[1]`. The active migration files are checked against a SHA-256/size manifest by `scripts/check-migration-history.sh`. The old local-only `20260916023400` draft was preserved in `supabase/archive/` because the production-applied `20260921041538` migration supersedes it.

### V3.15.7 audit_logs access

The local V3.15.7 migration now:

1. Resets client grants and restores only SELECT/INSERT to authenticated.
2. Removes the legacy permissive false policy left by the production V3.15.6 reconciliation. That policy does not deny access when other permissive policies apply; its removal clears obsolete policy state. The new restrictive guards enforce the tenant boundary.
3. Keeps restrictive tenant-membership checks for SELECT and INSERT.
4. Denies UPDATE and DELETE.
5. Verifies the legacy permissive false policy is absent, forbidden table/column privileges are absent, and service_role retains its operational grants.

### Automated migration verification

The migration workflow now runs a migration-history integrity gate and a focused PostgreSQL 17.6 job. It creates an isolated fixture, applies the recovered production reconciliation and pending V3.15.7 migration, then checks:

- RLS enabled but not forced, preserving trusted SECURITY DEFINER trigger writes.
- Narrow audit_logs table and column ACLs.
- Preservation of service_role access.
- The audit_logs restrictive tenant policy set.
- Member read/write success.
- Cross-tenant read/write denial.
- Removal of the legacy permissive false policy.

The focused audit_logs fixture and assertions, including a SECURITY DEFINER trigger write with NULL user_id, passed locally against PostgreSQL 17.11. The recovered production reconciliation migration and pending V3.15.7 migration completed successfully. A full 69-migration clean reset remains unverified because Docker is unavailable in this environment.

A root .gitignore was added for local dependencies, Supabase temporary state, local MCP configuration, environment files, logs, and backups.

## Remaining blockers

1. **Migration history reconciliation:** the production database has 69 migration records, while this repository does not contain the matching migration set. Reconstruct and commit the authoritative migration history before using db push.
2. **Branch synchronization:** the working branch is four commits behind `origin/main`; merge or rebase after reviewing local changes. The deployment workflow is manual build-readiness only because no application source or hosting provider is configured.
3. **Application source:** no application implementation is present in this checkout. TypeScript, lint, and application build validation cannot be run.
4. **Auth configuration:** enable leaked-password protection in the Supabase Auth settings after the project owner approves the setting change.
5. **Branch synchronization:** the working branch is four commits behind `origin/main`; merge or rebase after reviewing the local changes.

## Change boundary

All database inspection was read-only. No production migration was applied, no production grants or policies were changed, and no deployment was run.

The existing staged package.json and other user-created untracked files were preserved. Changes in this review remain local and uncommitted.
