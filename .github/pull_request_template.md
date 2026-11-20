## Change summary

- Problem / operational outcome:
- Scope and non-goals:
- Acceptance criteria:

## Risk and impact

- [ ] R0 Read-only
- [ ] R1 Local code/docs/tests
- [ ] R2 Database behavior / schema / ACL / RLS
- [ ] R3 Tenant, financial, identity, or cryptographic boundary
- [ ] R4 Production operation

Affected domains, tenants, roles, tables, APIs, jobs, and integrations:

## Database and security review

- [ ] No applied migration was edited or removed
- [ ] Migration ordering and production history were checked
- [ ] RLS, grants, views, functions, triggers, search paths, and default privileges reviewed as applicable
- [ ] Tenant isolation and denied behavior tested as applicable
- [ ] Data compatibility, locking, backfill, and rollback/forward-fix considered

## Verification evidence

| Check | Command / workflow | Result | Evidence link or notes |
|---|---|---|---|
| Static/diff | | | |
| Focused tests | | | |
| Integration/full replay | | | |
| Hosted CI | | | |
| Staging / production | | | |

Checks not run and why:

## Release and operations

- Deployment order / feature flags:
- Backup / recovery point (if data-affecting):
- Rollback or forward-fix plan:
- Monitoring and stop conditions:
- Required approvals:

## Final checklist

- [ ] No secrets or real environment files added
- [ ] No unrelated user changes staged
- [ ] Documentation and execution status updated
- [ ] Exact verification level stated; no unrun check reported as passed
