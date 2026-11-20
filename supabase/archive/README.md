# Archived migration drafts

`20260916023400_v3_15_6_rls_rejection_policies.sql` is preserved here from the committed repository version. It is not present in the production migration ledger and must not be replayed as an active migration.

Its 13-table `reject_all_public_access` work was superseded in production by the applied migrations:

- `20260917070958_nabuuma_v3156_service_table_explicit_rls_boundaries.sql`
- `20260921041538_nabuuma_v3156_service_table_explicit_rls_boundaries_reconcile.sql`

The active migration directory now uses the production-applied versions recovered from `supabase_migrations.schema_migrations.statements`. Keep this archive for provenance; do not move the draft back into `supabase/migrations` without a new migration-history review.

`20260916023400_v3_15_6_audit_logs_restrictive_draft.sql` is a separate ignored `.bak` draft recovered from the working directory. It targets only `public.audit_logs` and installs a restrictive false policy. It was superseded by the production-applied service-table boundary migrations and the pending, more complete V3.15.7 audit-log hardening. It is archived for provenance and must not be replayed.
