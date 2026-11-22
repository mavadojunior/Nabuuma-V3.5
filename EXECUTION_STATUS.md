# Current Release Gate — 2026-11-20

**Repository:** `mavadojunior/Nabuuma-V3.5`
**PR:** [#4 — feat: restore migration history and enforce release gates](https://github.com/mavadojunior/Nabuuma-V3.5/pull/4)
**Branch:** `enforce/release-readiness-v1`
**Latest verified code/test head:** `91b0818e3a43f860317e962a4d951069828316f6`
**Latest production-code commit:** `4ecabc6533bfbfeaf74bf199c14a330e63735124`
**CI-verified PR head recorded in this update:** `9ea44fe675a2b6d1fff04afbaa8924efefd7f2c8` (documentation-only refresh)
**Production project:** `mzfkamgfvxypakfkjdfs` (PostgreSQL 17.6)

## Current verified position

- PR #4 is open, unmerged, and reported mergeable. No reviewer is requested and no formal review is recorded.
- Database Migration Tests run [44677735534](https://github.com/mavadojunior/Nabuuma-V3.5/actions/runs/44677735534) passed all four jobs on documentation-only PR head `9ea44fe`, following verified code/test head `91b0818`. Microsoft Defender run [44677735416](https://github.com/mavadojunior/Nabuuma-V3.5/actions/runs/44677735416) also passed on that PR head.
- The full Supabase local-stack replay passed, including every recovered and pending migration, structural/security assertions, recipe publication tests, access-token hook tests, settlement execution/rollback, concurrent business onboarding, ACL regression fixtures, and view-ACL idempotency.
- New onboarding coverage verifies that simultaneous first-time `create_business()` calls resolve to one business, one membership, and one subscription.
- New recipe tests cover trusted service-role publication, user-membership authorization, replacement/archival, direct-publication denial, published-version immutability, cross-business references, and active-pointer integrity.
- Read-only production checks found zero active recipe pointers, zero cross-business recipe/product references, and zero products with multiple published recipe versions. These results satisfy the new migration preconditions.
- The production migration ledger contains 69 records and matches all 69 entries in the recovered migration manifest. No missing, mismatched, or extra records were found.
- Four migrations remain pending production approval: `20261019000000`, `20261114043000`, `20261114043100`, and `20261114043200`.
- Production checks were read-only. No production migration, schema, ACL, policy, or data changes were made.
- CodeRabbit's check is skipped and the bot stated that manual review is required for this OSS repository. The only listed repository collaborator is the repository owner; no independent reviewer is assigned. GitHub has no formal review submission or inline review thread.
- The `supabase_admin` default-privilege issue remains a platform-owned residual risk for future objects created by that role. The project migration role cannot change those managed defaults.

## Additional implementation in this continuation

- `create_business()` now takes a per-user transaction advisory lock before checking existing membership, preventing concurrent first-time requests from creating multiple businesses.
- The recipe publication path keeps the production service-role-only EXECUTE boundary. It serializes publication by locking the product, verifies the recipe/product/business relationship, and uses a controlled transaction-local authorization marker for publication state transitions.
- The recipe immutability trigger now blocks direct published inserts, updates, deletes, and unauthorized status changes. It permits only the controlled publication/archival path and returns `OLD` for allowed draft/archived deletes.
- Tenant-integrity SECURITY DEFINER trigger functions now use `search_path=pg_catalog` and are not directly executable by API roles.
- A product active-recipe guard rejects pointers to drafts, other products, or other businesses. Migration preconditions stop if existing pointers, recipe ownership, or published-version cardinality are inconsistent.

## Outstanding release actions

1. Obtain an independent human review of the current PR head and all four pending migrations.
2. Resolve review findings and rerun CI if any code changes are made.
3. Confirm backup/snapshot availability and capture fresh production schema, ACL, and migration-ledger evidence immediately before any deployment.
4. Apply migrations only after explicit authorization, one at a time, in timestamp order; verify catalog and ACL assertions after each commit.
5. Treat committed migrations as forward-only; prepare compensating migrations rather than relying on rollback SQL.

**Release status:** Latest code/test head and subsequent documentation-only refresh passed hosted CI; independent review pending; production deployment not authorized.

## Application Restoration Update — 2026-11-21

- An initial Next.js application slice has been restored in the local working tree from the verified V3.5 MVP archive: login, root redirect, shared layout/styles, dashboard, Supabase browser client, business membership/onboarding helpers, middleware, navigation, TypeScript path alias, and public environment-variable template.
- The uploaded login page, layout, and global stylesheet were compared with the V3.11 Integrated archive; their source content matches the V3.5 application lineage. The shared auth and tenant helpers are also unchanged between the V3.5 and V3.11 archives.
- The onboarding helper now re-reads membership after `create_business()`. This handles the function's `already_member` response, which returns the business identifier and role without the embedded business object. Membership query errors are no longer treated as an absent membership.
- The dashboard query now uses the recovered `products_active_recipe_fk` constraint, filters each read by the resolved `business_id`, and surfaces query errors. Navigation is limited to the restored dashboard route so it does not link to missing modules.
- Static verification passed: `bash scripts/engineering-preflight.sh`, JSON parsing for `tsconfig.json` and `package.json`, application-file presence checks, static auth/tenant contract checks, and whitespace checks on untracked files.
- Application build/typecheck/lint/integration tests remain blocked. The repository package manifest still contains only `aasvg`; the Next.js, React, and Supabase dependencies and a lockfile have not been restored. The npm registry request timed out (exit 124), and no TypeScript compiler is installed in the environment.
- The restored files are untracked local work. No package manifest, lockfile, migration, database, production state, Git history, commit, push, or deployment was changed.
- The uploaded live logistics security test was not run because it contains successful POD finalization writes. The uploaded seed SQL was not executed.

**Application status:** source slice restored locally; build and runtime verification blocked pending dependency resolution and test tooling. Do not treat this as a deployable application.

---

# Nabuuma V3.5 Execution Status

**Historical snapshot date:** 2026-11-14

> The sections below preserve the engineering status recorded on 2026-11-14. Where they describe CI as pending, the branch position as behind, or hosted replay as unverified, those statements are historical. Use the current release gate above for the latest verified status.
**Repository:** mavadojunior/Nabuuma-V3.5
**Production Instance:** mzfkamgfvxypakfkjdfs (PostgreSQL 17.6)

## Latest Repository Review — 2026-11-14

This is a local engineering update, not a production deployment.

- Reconstructed all 69 production-applied migration SQL statements from `supabase_migrations.schema_migrations.statements[1]`.
- `supabase migration list --linked`: 69 production migrations matched, zero remote-only; the current working tree has four pending local-only migrations (`20261019000000`, `20261114043000`, `20261114043100`, `20261114043200`).
- Archived the un-applied `20260916023400` draft because the production-applied `20260921041538` migration supersedes it.
- Added a SHA-256/size manifest and `scripts/check-migration-history.sh`; the integrity gate passes.
- The V3.15.7 `audit_logs` migration and focused PostgreSQL 17.11 regression tests pass locally. The GitHub workflow is configured for PostgreSQL 17.6; hosted CI has not run.
- Full `supabase db reset` remains unverified because Docker is unavailable in this UserLAnd environment.
- Production `public.audit_logs` still has broad client grants. V3.15.7 narrows client ACLs and keeps RLS enabled but not forced so trusted SECURITY DEFINER audit triggers continue to work; it is pending and not deployed.
- The branch is four commits behind `origin/main`. No rebase or push was performed.
- The checkout has no application source directories or package build/typecheck/lint scripts. The deployment workflow is manual build-readiness only and does not deploy.

See `docs/REPOSITORY_AUDIT_2026-11-14.md` and `docs/MIGRATION_HISTORY_RECONCILIATION_2026-11-14.md` for the evidence, recovered migration manifest, and remaining blockers.


## Follow-up Engineering Update — 2026-11-14

- Added migration `20261114043200_harden_legacy_trigger_search_paths.sql`. It sets `v21_audit_allocation_insert()` and `v22_audit_milestone()` to `search_path=pg_catalog` without changing their bodies, ownership, grants, or triggers.
- Added `supabase/tests/schema_reconciliation_assertions.sql` to verify the recipe FK correction, retained financial balance trigger, and both hardened SECURITY DEFINER function settings.
- Added a `full-schema-replay` GitHub Actions job using the Supabase CLI and PostgreSQL 17 local stack. It runs the complete migration chain, then structural and ACL assertions. The hosted job has not run yet.
- Local verification passed: migration 432 and structural assertions on the reconstructed full-schema database; the explicit ACL drift assertions and generic all-view ACL assertions also passed on that database.
- Four migrations are pending production approval: `20261019000000`, `20261114043000`, `20261114043100`, and `20261114043200`.
- Production catalog review found all 12 public views carry excessive API-role grants. All are `security_invoker` and report zero automatically updatable columns. Migration 431 now preserves `SELECT` and revokes every other API-role privilege from all public views; the ACL assertion checks every view and API role.
- The ACL comparison now covers 364 relation/role rows and 1,652 excess privilege bits (162 `anon`, 162 `authenticated`, 40 `service_role`), including 35 additional view-role rows beyond the earlier 329-row comparison. The updated CSV records the revised intended `SELECT`-only view grants.
- Local full-schema verification passed: 12 public views, zero missing API `SELECT` grants, zero views with API DML grants; the complete ACL assertion suite also passed.
- Added repository-wide `AGENTS.md`, `docs/ENGINEERING_WORKFLOW.md`, a pull-request template, and `scripts/engineering-preflight.sh`. The workflow defines risk classes, migration discipline, a six-level verification ladder, review/CI/release gates, post-deployment checks, and incident recovery.
- Added a repository preflight GitHub Actions job and expanded the full-schema job to reapply migration 431 and rerun ACL assertions across the full schema. Hosted CI has not run; local YAML parsing was unavailable in this environment.
- `bash scripts/engineering-preflight.sh` passed locally. It verifies the 69-file production migration manifest and both staged/unstaged diff whitespace; it does not replace PostgreSQL, hosted CI, staging, or production tests.
- Production confirms `postgres` is neither a member of `supabase_admin` nor a superuser. The platform-owned `supabase_admin` defaults grant API roles all table privileges, sequence SELECT/UPDATE/USAGE, and function EXECUTE on future public objects. Migration 431 cannot alter those defaults; an authorized Supabase-side fix remains mandatory. No production changes, commits, or pushes were made.

## Implementation Status Matrix

| Component | Version | Status | Evidence | Notes |
|-----------|---------|--------|----------|-------|
| **Database Layer** | | | | |
| Fiscal Control Plane | V3.5 | ✓ Implemented | Migrations + pgTAP tests | GCC tax, VAT, corporate tax infrastructure |
| Customs & Cross-Border | V3.6 | 📋 Planned | Schema designed | HS tariffs, manifests, state machines |
| Settlement Routing | V3.7 | 📋 Planned | Architecture drafted | Liquidity sources, route legs |
| Evidence & Oracles | V3.8 | 📋 Planned | Architecture drafted | SHA-256 digests, oracle evidence |
| Reconciliation | V3.9 | 📋 Planned | Schema designed | Financial divergence, repairs |
| Ledger Repair | V3.10 | 📋 Planned | Schema designed | Repair authorization, immutable guards |
| Forensic Continuity | V3.11 | 📋 Planned | Architecture drafted | Hash-chain verification |
| Production Certification | V3.12 | 🔧 In Progress | pgTAP framework | Schema, RLS, financial conservation tests |
| **Security Layer** | | | | |
| Tenant Authorization | V3.13 | ✓ Hardened | business_members enforcement, RLS | Cross-tenant isolation verified |
| API Security | V3.14 | ✓ Hardened | SECURITY INVOKER conversion, search_path | 36 → 21 → 0 authenticated SECURITY DEFINER |
| Function Authorization | V3.15 | 🔧 In Progress | 69 production migrations recovered; V3.15.7 audit_logs regression passed locally | Production audit_logs grants remain broad; V3.15.7 is pending |
| **Application Layer** | | | | |
| Authentication Boundary | – | 📋 Planned | Architecture documented | middleware.ts and application source are absent from this checkout |
| Authorization Services | – | 📋 Planned | Service layer skeleton | lib/authorization/ not yet implemented |
| Inventory Services | – | 📋 Planned | | |
| Procurement Services | – | 📋 Planned | | |
| Financial Services | – | 📋 Planned | | |
| Fiscal Services | – | 📋 Planned | | |
| Customs Services | – | 📋 Planned | | |
| **CI/CD & Verification** | | | | |
| Migration Tests | – | 🔧 In Progress | PostgreSQL 17.11 fixture and migration-history hash gate passed | PG17.6 GitHub workflow updated locally; hosted run pending |
| Security Tests | – | 🔧 In Progress | supabase/tests/v3_15_7_audit_logs_assertions.sql | Executable SQL assertions; no active pgTAP suite recovered |
| RLS Verification | – | 🔧 In Progress | Local PG17.11 fixture and production catalog inspection | Production ACL remediation remains pending |
| Build Pipeline | – | 📋 Planned | | |
| TypeScript Verification | – | 📋 Planned | | |
| Type Generation | – | 📋 Planned | supabase types generation | |

## Legend

- ✓ **Implemented** — Migrations deployed, code committed, tests passing, production verified
- 🔧 **In Progress** — Actively being developed; partially complete or awaiting merge
- 📋 **Planned** — Designed; awaiting implementation; architecture documented
- ✗ **Not Started** — Not yet designed or scoped

## Current Verification Status

### Production Database (mzfkamgfvxypakfkjdfs) — Historical snapshot

| Check | Status | Details |
|-------|--------|---------|
| PostgreSQL Version | ✓ 17.6 | Production-matched |
| Public SECURITY DEFINER exposure | ✓ 0 | V3.15.3 hardening applied |
| Anonymous SECURITY DEFINER execution | ✓ 0 | No unauthenticated privileged access |
| RLS on public tables | ✓ Enforced | _nabuuma_deployment_bootstrap, stock_transfer_batch_lines |
| Service-role boundaries | ✓ Established | 13 service-only RLS tables identified |
| Tenant isolation (RLS) | ✓ Verified | business_members enforcement in RLS policies |
| Search path hardening | ✓ Complete | Mutable search_path: 9 → 0 in SECURITY DEFINER functions |

### GitHub Repository

| Check | Status | Details |
|-------|--------|---------|
| README.md | ✓ Complete | Architecture, principles, engineering rules |
| Migrations directory | ✓ Recovered | 69 production SQL statements + one pending V3.15.7 migration |
| SQL regression tests | 🔧 In progress | V3.15.7 audit_logs assertions; PG17.11 pass |
| Architecture documentation | 🔧 In progress | Staged in enforce branches; needs merge |
| Security documentation | 📋 Planned | SECURITY.md to be created |
| CI/CD workflows | 🔧 In progress | Migration integrity gate + PG17.6 test workflow; deployment is manual build-only |
| Environment template | 📋 Planned | .env.example to be created |
| Type definitions | 📋 Planned | types/database.ts generation |

## Branches — Historical Snapshot

| Branch | Status | Purpose |
|--------|--------|---------|
| `main` | ✓ Current | Production source branch |
| `enforce/db-migration-tests-v2` | 🔧 Ready for merge | Enforcement-grade workflows + security audit docs + pgTAP tests |
| `enforce/v3.15.6-rls-rejection-policies` | 🔧 Ready for merge | V3.15.6 migration + RLS rejection policies |

## Next Actions — Historical 2026-09-16 Snapshot

The following list predates the 2026-11-14 repository review above. Use the latest review and audit document for current deployment blockers.

### Immediate (Next Session)

1. **Merge `enforce/db-migration-tests-v2` → `main`**
   - Enforces migration testing standards
   - Captures V3.15.2-3 hardening in audit documentation
   - Adds pgTAP security tests
   - Status: Ready for merge; awaiting approval

2. **Verify V3.15.6 RLS rejection policies**
   - Execute migration against production test environment
   - Capture pgTAP verification results
   - Create GitHub Actions artifact
   - Then merge `enforce/v3.15.6-rls-rejection-policies` → `main`

### Short-term (Next Sprint)

3. **Create core contract documents**
   - DATABASE_CONTRACT.md
   - SECURITY_CONTRACT.md
   - API_CONTRACT.md

4. **Create architecture documentation**
   - SYSTEM_ARCHITECTURE.md
   - SECURITY_ARCHITECTURE.md
   - DATA_ARCHITECTURE.md (tenant isolation, RLS)
   - FINANCIAL_ARCHITECTURE.md (precision, conservation)
   - AUTHORIZATION_MODEL.md (two-layer boundary)

5. **Create operational documentation**
   - EXECUTION_RUNBOOK.md
   - PRODUCTION_VERIFICATION.md
   - REPOSITORY_CERTIFICATION.md

6. **Create CI/CD enforcement**
   - Typecheck workflow
   - Build workflow
   - Prevent `continue-on-error: true` on critical tests

### Medium-term

7. **Application layer implementation**
   - Authorization service layer
   - Supabase client boundaries
   - Error handling contract
   - Audit model

8. **Complete V3.5 fiscal control**
   - Verify gcc_tax_ledger implementation
   - Verify financial conservation (debits = credits)
   - Complete pgTAP tests for fiscal functions

## Definition: "Implemented"

A Nabuuma V3.5 feature is considered **implemented** only when all of the following are true:

```
DOCUMENTED (architecture + contract)
    ↓
CODED (database migration or application code)
    ↓
TESTED (pgTAP for DB, unit tests for app)
    ↓
SECURED (authorization enforced, RLS applied, secrets not exposed)
    ↓
DEPLOYED (migration applied to production or app code merged)
    ↓
VERIFIED (CI passed, artifact captured, deployment confirmed)
```

A feature that exists at any intermediate stage is marked as **In Progress** or **Planned**, not **Implemented**.

A README claim does not constitute implementation.

## Known Gaps

1. **Supabase functions** — Need to verify `supabase/functions/` structure and function implementations
2. **Application routes** — Need to verify `app/` structure matches declared architecture
3. **Service layer** — `lib/` services need explicit authorization boundaries
4. **Type generation** — `types/database.ts` must be auto-generated from Supabase schema
5. **Environment configuration** — `.env.example` needed with required variables
6. **Migration history** — Migration files for V1.3-V3.5 need to be audited for correctness
7. **pgTAP coverage** — Need comprehensive tests for:
   - Tenant isolation (cross-tenant denial)
   - Financial conservation (debit/credit balance)
   - Append-only enforcement
   - Function authorization (unauthorized role rejection)

## Verification Artifacts

- **CI/CD:** `.github/workflows/db-migration-tests.yml` (enforcement-grade)
- **Security Audit:** `docs/security-hardening-v3.15.md` (audit trail)
- **pgTAP Tests:** `supabase/tests/security-audit.sql` (authorization verification)
- **Archived migration:** `supabase/archive/20260916023400_v3_15_6_rls_rejection_policies.sql` — preserved byte-for-byte for provenance; absent from the production migration ledger and excluded from active migration replay. Superseded by production-applied migration `20260921041538`.

---

**Repository is a work-in-progress toward the canonical Nabuuma V3.5 specification.**

**No feature is considered production-ready until this matrix reflects ✓ Implemented status.**


## Dependency Restoration & Build Gate — 2026-11-21

**Status:** application source, pinned dependencies, lockfile, typecheck, lint, and production build are restored and verified. Authentication/RLS integration remains blocked by the absence of a local Supabase runtime. Products and Recipes work must remain on hold until that integration gate passes.

### Restored runtime

- Runtime baseline: Node.js `>=22.0.0`; verification runtime Node `22.23.3`.
- Package manager: pnpm `10.28.2`; `pnpm-lock.yaml` is the authoritative lockfile. The old minimal npm lockfile was removed.
- Pinned runtime dependencies: `next@16.4.6`, `react@19.3.1`, `react-dom@19.3.1`, `@supabase/ssr@0.12.7`, `@supabase/supabase-js@2.119.2`, `qrcode@1.5.4`, and preserved `aasvg@0.4.3`.
- Pinned development dependencies: `typescript@5.9.3`, `eslint@9.39.5`, `eslint-config-next@16.4.6`, `@types/node@22.19.0`, `@types/react@19.3.0`, and `@types/react-dom@19.3.0`.
- `package.json` defines `typecheck`, `lint`, `build`, and explicitly local-only `test:db` scripts.
- Next.js 16 session handling now uses root `proxy.ts` and `supabase.auth.getClaims()`. The browser client accepts a Supabase publishable key, with legacy anon-key fallback. No service-role or secret key is exposed.
- `next build --webpack` is the build command because Turbopack fails on this UserLAnd filesystem with `Invalid symlink: Invalid argument (os error 22)`.

### Verification evidence

| Check | Result | Evidence |
|---|---|---|
| Dependency install | PASS | `pnpm install --frozen-lockfile` completed with pnpm 10.28.2 |
| TypeScript | PASS | `pnpm run typecheck` under Node 22.23.3, including the final `@types/node@22.19.0` update |
| Lint | PASS | `pnpm run lint` under Node 22.23.3 |
| Production build | PASS | `pnpm run build` (`next build --webpack`); compiled, completed TypeScript, generated static pages, and emitted `/`, `/dashboard`, `/login`, and `/_not-found` |
| Repository preflight | PASS | `bash scripts/engineering-preflight.sh`; 69 migration files match the recovered manifest |
| Whitespace | PASS | `git diff --check` |
| Local DB integration | BLOCKED | `supabase test db --local` stopped before tests: connection refused at `127.0.0.1:54322`; Docker is not installed and no local Postgres listener is running |

### Remaining acceptance gate

1. Provide a local Supabase runtime with Docker, or an isolated disposable staging Supabase project approved for integration testing.
2. Run the existing pgTAP database suite locally and add/execute the application authentication and tenant-isolation integration checks against that isolated environment.
3. Verify unauthenticated denial, authenticated membership resolution, tenant boundary enforcement, and denied cross-tenant reads/writes. Do not run the write-bearing suite against production.
4. Only after those checks pass, begin the Products and Recipes vertical slice.

No `.env.local` credentials were created. No production database tests, migrations, data changes, deployments, commits, or pushes were performed. The application has not yet been runtime-authenticated against a real Supabase Auth service.


## Application and Local Verification Update — 2026-11-22

**Scope:** restored first Next.js application slice and no-cost local verification only.

- Runtime used: Node.js `22.23.3`, pnpm `10.28.2`.
- TypeScript: PASS (`pnpm typecheck`, exit 0).
- ESLint: PASS (`pnpm lint`, exit 0).
- Production build: PASS (`pnpm build`, `next build --webpack`, exit 0). Webpack compilation, Next.js TypeScript phase, static generation of all five pages, and build tracing completed. The build emits `/`, `/dashboard`, `/login`, and `/_not-found`; request protection is handled by `proxy.ts`.
- Vitest: PASS, 2 files and 10 tests. These tests mock `@supabase/ssr`; they verify the browser-client configuration and request/session boundary but do not call GoTrue.
- Native PostgreSQL Auth/RLS acceptance: PASS. `pnpm test:db` recreated only the guarded disposable database `nabuuma_rls_test`, replayed all 73 migrations with the documented test-only pg_cron override, and passed all eight SQL suites with `FINAL_SQL_ACCEPTANCE_FAILURES=0`.
- Destructive-runner guard: PASS. Setting `TEST_DB=postgres` is rejected with exit 2 before any database operation.
- Full local Supabase stack: BLOCKED by environment. `supabase status` reports `docker: command not found (podman also not found)`. Therefore the GoTrue Auth HTTP service and full container-backed Supabase integration were not run.
- Workflow correction: `test:db` now invokes the native PostgreSQL replay runner; `test:db:supabase` retains the optional Docker/Podman-backed Supabase CLI test. The native runner refuses database names other than `nabuuma_rls_test`. Generated test logs are ignored by Git.
- Security boundary remains HOLD: the SQL runtime CRUD matrix exercises `public.products` across anon, cross-tenant authenticated, authorized owner, and service-role contexts. It does not yet provide per-operation runtime coverage for every tenant-scoped table. Catalog RLS coverage is not a substitute for that matrix.

**Production and cloud boundary:** no hosted Supabase write, migration, data change, deployment, or paid cloud resource was used. Products and Recipes remain on hold pending full Auth runtime verification and broader tenant-table acceptance coverage.
