# Current Release Gate — 2026-11-17

**Repository:** `mavadojunior/Nabuuma-V3.5`
**PR:** [#4 — feat: restore migration history and enforce release gates](https://github.com/mavadojunior/Nabuuma-V3.5/pull/4)
**Branch:** `enforce/release-readiness-v1`
**Reviewed head at update:** `4ba31f9c20b0ba386ac922c4536319586f71dd32`
**Production project:** `mzfkamgfvxypakfkjdfs` (PostgreSQL 17.6)

## Current verified position

- PR #4 is open, unmerged, and reported mergeable. The branch is 15 commits ahead of `main`, 0 behind at the time of this check.
- Latest head CI passed: Database Migration Tests run [43996903591](https://github.com/mavadojunior/Nabuuma-V3.5/actions/runs/43996903591) (all four jobs) and Microsoft Defender run [43996903571](https://github.com/mavadojunior/Nabuuma-V3.5/actions/runs/43996903571).
- The full Supabase migration replay, ACL regression checks, and settlement execution/rollback assertions passed.
- The production migration ledger contains 69 records and matches all 69 entries in the recovered migration manifest. No missing, mismatched, or extra records were found.
- Four migrations remain pending production approval: `20261019000000`, `20261114043000`, `20261114043100`, and `20261114043200`.
- Production checks in this update were read-only. No production migration, schema, ACL, policy, or data changes were made.
- CodeRabbit paused its review at `3fea9dbe`; its own PR comment identifies `4ba31f9c` as not reviewed. A fresh independent review of the latest commit is still required.
- Production deployment remains blocked pending independent review, backup/snapshot and fresh pre-deployment fingerprints, controlled one-at-a-time application, post-migration assertions, and explicit release authorization.
- The `supabase_admin` default-privilege issue remains a platform-owned residual risk for future objects created by that role. The project migration role cannot change those managed defaults.

## Outstanding release actions

1. Obtain a fresh review covering the latest PR head, including all four pending migrations and the CI workflow changes.
2. Resolve review findings and rerun CI if any code changes are made.
3. Confirm backup/snapshot availability and capture fresh production schema, ACL, and migration-ledger evidence immediately before any deployment.
4. Apply migrations only after explicit authorization, one at a time, in timestamp order; verify catalog and ACL assertions after each commit.
5. Treat committed migrations as forward-only; prepare compensating migrations rather than relying on rollback SQL.

**Release status:** CI validation green; independent review pending; production deployment not authorized.

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
