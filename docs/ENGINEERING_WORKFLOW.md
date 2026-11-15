# Nabuuma V3.5 Engineering Workflow

**Status:** Working engineering standard for this repository.
**Scope:** Database, security, application, CI/CD, and operational changes. The current checkout is primarily a database/security workspace; application gates become mandatory when application source is introduced.

## 1. Operating principles

1. **Evidence before claims.** A design, local test, hosted CI run, and production verification are different evidence levels. Report each separately.
2. **Database authority.** Authorization, tenant boundaries, financial invariants, and transactional correctness must be enforced server-side and, where applicable, in PostgreSQL.
3. **Least privilege by default.** Grants, RLS, views, functions, triggers, default privileges, and service-role access are reviewed as one security boundary.
4. **Migration provenance is immutable.** Never edit or delete an applied migration. Recover history and verify its identity before reconciling it.
5. **Small reversible changes.** Prefer focused patches, additive migrations, explicit rollback/forward-fix plans, and isolated commits.
6. **No implied authorization.** Access to a repository, database, device, or connector does not authorize writes, production changes, commits, pushes, merges, or deployments.
7. **No false green.** Skipped, unavailable, flaky, or unexecuted checks are reported as such.

## 2. Work intake and risk classification

Before editing, write down:

- The operational problem and expected outcome.
- In-scope and out-of-scope components.
- Data, tenants, roles, APIs, jobs, and integrations affected.
- Whether the change is read-only, application-only, schema-changing, security-sensitive, financial, or production-impacting.
- Required evidence and the person/system that can authorize release.

Classify risk:

| Class | Examples | Minimum handling |
|---|---|---|
| R0 — Read-only | Documentation, catalog inspection | Confirm no writes; cite evidence and date |
| R1 — Local code | Pure application logic, docs, tests | Focused tests, diff review, CI |
| R2 — Database behavior | Schema, policies, grants, functions, triggers | Migration review, clean replay, upgrade-path test, security assertions, rollback/forward-fix plan |
| R3 — Sensitive operations | Tenant authorization, financial ledger, identity, cryptographic evidence | R2 plus adversarial tests, independent review, explicit release approval, recovery evidence |
| R4 — Production operation | Linked migration, data repair, deploy, secret rotation | Explicit operation-specific approval, backup/recovery check, maintenance/impact plan, monitored execution and post-checks |

Raise the class when a change crosses boundaries. Do not lower a class because the SQL or patch is small.

## 3. Repository and change isolation

At task start:

1. Confirm repository path, branch, remote, and latest commit.
2. Inspect `git status --short`, `git diff`, and `git diff --cached`.
3. Identify unrelated staged, unstaged, and untracked files. Preserve them.
4. Read `AGENTS.md`, relevant contracts, current status, and existing implementation/tests.
5. Confirm tool/CLI versions and inspect command help before using unfamiliar flags.

Use one focused branch and one reviewable change set per engineering outcome. Keep generated artifacts out of source control unless they are intentional, reproducible deliverables. Never mix unrelated user changes into a commit.

## 4. Implementation workflow

### 4.1 Plan

- State invariants that must remain true.
- Identify callers, dependencies, persistence boundaries, authorization boundaries, and failure modes.
- Choose the smallest design that satisfies the requirement.
- Define acceptance tests before implementation.
- For architecture changes, record the decision and alternatives in a short ADR under `docs/decisions/` when the decision has lasting impact.

### 4.2 Implement

- Follow established patterns; avoid duplicate abstractions and speculative frameworks.
- Keep business rules in the authoritative layer. Do not rely on UI filtering for authorization.
- Handle invalid input, missing data, retries, duplicate requests, concurrency, and partial failure.
- Keep logs useful but free of credentials, tokens, payment details, and unnecessary personal data.
- Add a regression test for every confirmed defect where practical.

### 4.3 Database migration rules

1. Check `supabase --version` and `supabase migration new --help`. Create a migration using the CLI; do not invent timestamps or overwrite migration history.
2. Confirm the latest production migration and local/remote migration list before writing SQL.
3. Never modify a production-applied migration. Use a new forward migration for corrections.
4. Make DDL transactional where supported. Use bounded `lock_timeout` and `statement_timeout` for production-facing changes.
5. Consider locks, table size, index build behavior, backfill duration, replication, dependencies, and deployment ordering.
6. Review grants, RLS, policies, view `security_invoker`, function `SECURITY DEFINER`/`search_path`/EXECUTE ACLs, trigger attachments, and default privileges.
7. Prefer expand → migrate/backfill → verify → contract for changes that cannot be deployed atomically with application code.
8. Test a clean full replay and an upgrade path seeded with the relevant production shape. Test idempotency only where the migration is intentionally written to support it.
9. Check migration ledger state after deployment. Never assume a successful SQL response alone proves migration bookkeeping is correct.
10. If rollback is unsafe or impossible, state that plainly and prepare a forward-fix/data-recovery plan.

Do not run `supabase db reset` against a linked database. Local reset is destructive to the local database and must be used only when the target and consequences are clear.

## 5. Verification ladder

Run checks from cheapest to most representative. Stop and diagnose failures rather than retrying blindly.

| Level | Evidence | Examples |
|---|---|---|
| L0 — Static | Files and diffs are structurally sound | `git diff --check`, format/lint check, migration filename/manifest validation |
| L1 — Focused local | Changed unit or SQL behavior | Unit tests, targeted PostgreSQL assertions, pgTAP |
| L2 — Integrated local | Components work together | Clean migration replay, production-shaped fixture, upgrade test, application integration tests |
| L3 — Hosted CI | Reproducible hosted environment | Required GitHub Actions checks, retained logs/artifacts |
| L4 — Staging | Environment-specific behavior | Auth/RLS integration, smoke tests, performance and operational checks |
| L5 — Production | Actual deployed state | Migration ledger, catalog/ACL/RLS checks, critical-path smoke tests, telemetry |

A check is green only when its command ran successfully and the output was inspected. A local result does not imply hosted CI or production success.

### Database security test minimums

- Test allowed and denied operations for `anon`, `authenticated`, and service roles as applicable.
- Test cross-tenant reads and writes, including forged tenant identifiers.
- Test RLS with the actual runtime roles, not only as the table owner or `postgres`.
- Test view grants and `security_invoker` behavior.
- Test privileged function ownership, `search_path`, EXECUTE grants, authorization checks, and trigger invocation.
- Test append-only and financial conservation constraints, duplicate/replay behavior, and transaction rollback.
- Inspect effective privileges, including inherited `PUBLIC` grants and default privileges.

### Application test minimums (when application code exists)

- Typecheck, lint, unit tests, integration tests, and production build.
- Auth/session lifecycle and server/client boundary tests.
- Tenant isolation and direct API authorization tests.
- Empty, invalid, boundary, retry, timeout, offline, and duplicate-submission cases.
- Accessibility, responsive behavior, and critical user journeys.
- Dependency audit and secret scanning appropriate to the stack.

Do not add placeholder npm scripts just to satisfy a CI workflow. Add application checks when the actual application and its test configuration exist.

## 6. Pull request and review standard

Every pull request must explain:

- Problem, scope, and acceptance criteria.
- Architecture/data/security impact.
- Migration versions and compatibility/deployment order, if applicable.
- Tests run, exact results, and checks not run.
- Operational impact, monitoring, rollback or forward-fix plan.
- Any unresolved risk or external dependency.

Reviewers check correctness, authorization, data integrity, concurrency, failure handling, test quality, migration safety, observability, and documentation. Security-sensitive, financial, tenant-boundary, and production changes require a second human review before release.

## 7. CI policy

Required CI should be deterministic, bounded by timeouts, and fail closed. Do not use `continue-on-error` for required security, migration, test, or build gates. Pin tool versions and dependency lockfiles.

For the current database/security workspace, the intended required gates are:

1. Migration-history manifest integrity.
2. PostgreSQL-version-matched focused security fixtures.
3. Relation and function ACL reconciliation assertions, including public views.
4. Full Supabase local-stack migration replay from an empty local database.
5. Structural/schema assertions and migration idempotency where intended.
6. Diff/format checks and workflow syntax validation.

When application source is introduced, add typecheck, lint, unit/integration tests, and build as required checks. Until then, the deployment-readiness workflow must remain blocked and must not claim to deploy.

CI must never connect to production or run a production migration. Use synthetic fixtures and disposable databases.

## 8. Release and production change control

A production release requires all of the following:

- Reviewed change set and explicit approval for the exact production operation.
- All required hosted CI checks green on the exact commit to be released.
- Migration history reconciled; no unexplained local/remote drift.
- Backup/PITR availability confirmed and restore procedure known for data-affecting work.
- Lock/availability impact and maintenance window assessed.
- Rollback or forward-fix plan documented, including data compatibility.
- Secrets and environment configuration verified without exposing secret values.
- Staging verification completed for high-risk changes.
- Named operator, execution window, monitoring, and stop conditions recorded.

Execute one controlled change at a time. Capture the commit SHA, migration versions, start/end times, tool output, and resulting migration ledger state. Stop on unexpected lock waits, errors, row-count deviations, privilege drift, or health regression. Do not improvise destructive recovery.

## 9. Post-deployment verification

After a production change:

1. Confirm the exact migration versions are recorded once.
2. Recheck schema objects, constraints, indexes, policies, RLS flags, grants, function settings, and triggers touched by the change.
3. Run read-only smoke tests for critical workflows and authorization boundaries.
4. Check error rates, latency, lock waits, queue health, and relevant business metrics.
5. Compare expected and actual row counts or financial control totals where relevant.
6. Record evidence and any residual risk in `EXECUTION_STATUS.md` and the release record.

A successful migration is not proof that the application workflow works. A successful smoke test is not proof that all tenants and roles are isolated.

## 10. Incident and recovery workflow

- Stabilize and preserve evidence before attempting repairs.
- Identify blast radius, affected tenants/data, last known good state, and whether writes must be paused.
- Prefer reversible containment. Do not delete or rewrite audit/ledger/provenance evidence.
- Use backups, restore points, and rehearsed recovery steps; never claim a restore is viable without evidence.
- Record commands, timestamps, affected versions, approvals, and validation results.
- After recovery, add a regression test and update the runbook.

## 11. Engineering status vocabulary

Use these labels consistently:

- **Designed:** approach documented; not implemented.
- **Implemented locally:** code or migration exists in the working tree.
- **Locally verified:** relevant local checks passed.
- **CI verified:** required hosted checks passed on the exact commit.
- **Staging verified:** tested in the designated staging environment.
- **Production deployed:** the exact approved change was applied successfully.
- **Production verified:** post-deployment checks passed against actual production state.
- **Blocked:** a named dependency or failed gate prevents progression.

Never collapse these states into a generic “complete.”

## 12. Current workspace boundary

As of the current repository audit, this checkout contains database/security migrations, tests, documentation, and workflow files, but not the complete Next.js application. Do not run or report app build/typecheck/lint/test gates until the actual app and scripts exist. The `supabase_admin` default-privilege issue and unexecuted hosted full replay remain release blockers until separately resolved and verified.
