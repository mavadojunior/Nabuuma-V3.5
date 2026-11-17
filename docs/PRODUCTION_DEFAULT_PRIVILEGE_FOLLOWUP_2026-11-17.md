# Production default-privilege follow-up

**Date:** 2026-11-17  
**Project:** `mzfkamgfvxypakfkjdfs`  
**Database:** PostgreSQL 17.6  
**Access:** Read-only production catalog queries. No production DDL or data changes.

## Production findings

| Catalog check | Result |
|---|---:|
| `postgres` schema-specific default ACL entries in `public` | 3 |
| `supabase_admin`-owned objects in `public` | 0 |
| Extensions installed in `public` | 0 |
| `postgres`-owned functions in `public` | 143 |
| Existing `postgres`-owned public functions with `PUBLIC EXECUTE` | 24 |

The three `postgres` schema-specific default ACL entries in `public` grant privileges only to the owner. The effective global default function ACL still includes `PUBLIC EXECUTE`. The 24 existing public functions with `PUBLIC EXECUTE` are part of the current function ACL state; the repository's production comparison reported zero function-EXECUTE delta against the reconstructed migration state. This change does not revoke or rewrite any existing function ACL.

The production catalog also confirms that `is_member(uuid)`, used by application authorization, is a `SECURITY DEFINER` helper with explicit grants to `authenticated` and `service_role` (and an existing explicit `anon` grant). `current_user_id()` and `is_admin()` have their existing ACLs. These grants remain unchanged.

Supabase Support confirmed that `supabase_admin` defaults are managed platform configuration and apply only to objects created by that role. Production has no `supabase_admin`-owned objects or extensions in `public`, so those defaults currently have no public-schema objects to affect. No customer-side SQL path exists to alter the managed defaults. Keep extensions in a non-exposed schema where supported; contact Supabase Support for extensions that cannot be relocated safely.

Reference: [Supabase KB — Can't change the default privileges of `supabase_admin` in the `public` schema](https://supabase.com/kb/troubleshooting/cant-change-the-default-privileges-of-supabase_admin-in-the-public-schema-448af9).

## Implemented repository control

Migration `20261114043100_restore_client_acl_boundaries.sql` now sets future-object defaults for objects created by `postgres`:

- Revoke all default table privileges from `anon`, `authenticated`, and `service_role` in `public`.
- Revoke all default sequence privileges from those API roles in `public`.
- Revoke all default function privileges from those API roles in `public`.
- Revoke global default `EXECUTE` from `PUBLIC` for functions created by `postgres`. This is deliberately not schema-scoped; PostgreSQL adds per-schema defaults to global defaults, so a schema-specific revoke cannot remove global `PUBLIC EXECUTE`.

These changes apply only to objects created after the migration and only when `postgres` is the creating role. Existing object ACLs are unchanged. Defaults owned by `supabase_admin` or another role are unchanged.

**Migration-author requirement:** explicitly grant each new table, sequence, RPC, and RLS helper the minimum privileges it needs. An RLS helper must be executable by the role evaluating the policy. A new RPC must be executable only by its intended caller. This applies to `postgres`-created functions in every schema, not just `public`.

## Verification

- Isolated PostgreSQL 17 runtime probe passed: new table, sequence, and function had no API-role access; new function had no `PUBLIC EXECUTE`; explicit `authenticated` and `service_role` grants worked while `anon` remained denied.
- GitHub Actions run [43985400113](https://github.com/mavadojunior/Nabuuma-V3.5/actions/runs/43985400113) passed all four jobs on commit `cc05e56607bce530e3e3429aaababddfd0722fdb`:
  - Repository integrity and engineering preflight.
  - PostgreSQL 17.6 `audit_logs` least-privilege regression.
  - PostgreSQL 17.6 relation and public-view ACL reconciliation, including migration idempotency.
  - Full Supabase local-stack migration replay, structural assertions, ACL assertions, and migration idempotency.
- `actionlint` passed for all three workflows; `git diff --check` passed.

## Release boundary

The four forward migrations remain pending production approval. No migration was applied to production. No production schema, ACL, policy, or data was changed. PR #4 remains open and unmerged.
