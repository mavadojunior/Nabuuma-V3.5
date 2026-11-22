# Nabuuma V3.5 — Local Auth/RLS execution report

## Runtime

- Native PostgreSQL: 17.11 (ARM64), user-owned data directory
- Local port: `55432`; Unix socket: `/tmp`; SSL disabled for this isolated test instance
- Disposable database: `nabuuma_rls_test`
- Rebuild command: `./test/run-local-db.sh`
- Bootstrap: `test/bootstrap_supabase_shim.sql`

## Migration replay

- 73 migration files replayed in lexicographic chronological order.
- Final end-to-end replay completed successfully.
- One test-only override omits the `CREATE EXTENSION pg_cron` statement from migration `20260906040154_nabuuma_v1_7_demand_intelligence.sql`. The original migration is unchanged; this migration has no `cron.*` calls. Native `pg_cron` execution is not covered.
- Supabase-only compatibility objects are test-only: `anon`, `authenticated`, `service_role` (`BYPASSRLS`), `supabase_auth_admin`, `auth.users`, `auth.uid()`, `auth.jwt()`, `auth.role()`, and extension wrappers.
- Source migration SHA-256 manifest: `test/logs/migration-source.sha256`.

## Verified database tests

Final deterministic run: `test/logs/final-sql-acceptance.log`.

| Suite | Result |
|---|---|
| ACL reconciliation | PASS |
| Custom access-token hook | PASS |
| Recipe publishing | PASS |
| Schema reconciliation | PASS |
| Settlement execution | PASS |
| V3.15.7 audit logs | PASS |
| RLS catalog matrix | PASS |
| RLS runtime core CRUD matrix | PASS |

`FINAL_SQL_ACCEPTANCE_FAILURES=0`.

Catalog checks found 153 RLS-enabled public base tables, including two test-only fixtures. No table lacked RLS. `anon` had zero table-level CRUD privileges on all 153. `service_role` retained `BYPASSRLS` and is not a superuser.

Runtime CRUD behavior was exercised for `public.products` across anon, cross-tenant authenticated, authorized owner, and service-role contexts. Existing recipe, audit-log, token-hook, and settlement suites also passed.

## Application Auth tests

- Vitest: 2 files, 10 tests passed.
- Tests mock `@supabase/ssr` browser/server clients and Auth claim/session responses; no live Supabase Auth requests were made.
- `pnpm run typecheck` passed after adding the Vitest tests.

## Remaining gate items

- The requested per-operation runtime matrix has not yet been executed separately for every one of the 151 application tables. Catalog coverage is not a substitute for tenant-owner fixture tests. The full Auth/RLS gate therefore remains **HOLD**.
- ESLint and the latest Next.js production build attempts were stopped after extended CPU-bound execution on UserLAnd. Do not treat those latest attempts as passes. A previous build had passed before the Vitest additions.
- No Products or Recipes migrations were changed or approved. No hosted Supabase branch, production migration, or cloud resource was created.


## 2026-11-22 rerun

- `pnpm typecheck`: PASS.
- `pnpm lint`: PASS.
- `pnpm build` (`next build --webpack`): PASS; compilation, TypeScript, static page generation, and build tracing completed.
- `pnpm test:auth`: PASS; 2 files, 10 tests. Supabase clients are mocked; this is not a live GoTrue test.
- `pnpm test:db`: PASS; 73 migrations replayed and all eight SQL acceptance suites passed with zero failures. The runner uses isolated native PostgreSQL 17 and a test-only Supabase compatibility shim.
- `TEST_DB=postgres bash test/run-local-db.sh`: correctly refused the unexpected database name before destructive operations.
- `supabase status`: unavailable because neither Docker nor Podman is installed. Full GoTrue HTTP/Auth integration remains unverified.
- Runtime CRUD coverage remains focused on `public.products`; a full per-table tenant matrix remains outstanding. Auth/RLS release gate remains HOLD.
