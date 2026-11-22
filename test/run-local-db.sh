#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO/test"
MIGRATIONS="$REPO/supabase/migrations"
PGROOT="${PGDATA:-$HOME/.local/share/postgresql/nabuuma-test}"
PGBIN="${PGBIN:-/usr/lib/postgresql/17/bin}"
PORT="${PGPORT:-55432}"
DB="${TEST_DB:-nabuuma_rls_test}"
if [[ "$DB" != "nabuuma_rls_test" ]]; then
  echo "Refusing to drop unexpected database name: $DB" >&2
  echo "This runner is restricted to the disposable nabuuma_rls_test database." >&2
  exit 2
fi
DB_ADMIN="${DB_ADMIN_USER:-userland}"
MIGRATION_ROLE="${MIGRATION_ROLE:-postgres}"
LOG_DIR="$TEST_DIR/logs"
mkdir -p "$LOG_DIR"

if ! "$PGBIN/pg_ctl" -D "$PGROOT" status >/dev/null 2>&1; then
  "$PGBIN/pg_ctl" -D "$PGROOT" -l "$PGROOT/server.log" \
    -o "-p $PORT -h 127.0.0.1 -c ssl=off -c unix_socket_directories=/tmp -c listen_addresses=127.0.0.1" \
    -w start
fi

PSQL=(psql -X -h /tmp -p "$PORT")
DBCTL=( -h /tmp -p "$PORT" )
"${PSQL[@]}" -U "$DB_ADMIN" -d postgres -v ON_ERROR_STOP=1 \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid <> pg_backend_pid();" >/dev/null
if "${PSQL[@]}" -U "$DB_ADMIN" -d postgres -Atqc \
  "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1; then
  dropdb "${DBCTL[@]}" -U "$DB_ADMIN" "$DB"
fi
createdb "${DBCTL[@]}" -U "$DB_ADMIN" -O "$DB_ADMIN" "$DB"
"${PSQL[@]}" -U "$DB_ADMIN" -d "$DB" -v ON_ERROR_STOP=1 \
  -f "$TEST_DIR/bootstrap_supabase_shim.sql" > "$LOG_DIR/bootstrap.log" 2>&1

mapfile -t FILES < <(find "$MIGRATIONS" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sort)
if [[ "${#FILES[@]}" -ne 73 ]]; then
  echo "Expected 73 migrations, found ${#FILES[@]}" >&2
  exit 1
fi
sha256sum "${FILES[@]/#/$MIGRATIONS/}" > "$LOG_DIR/migration-source.sha256"
: > "$LOG_DIR/migration-replay.log"

for i in "${!FILES[@]}"; do
  f="${FILES[$i]}"
  printf '\n=== APPLY %02d/%02d %s ===\n' "$((i+1))" "${#FILES[@]}" "$f" \
    | tee -a "$LOG_DIR/migration-replay.log"
  if [[ "$f" == 20261114043100_restore_client_acl_boundaries.sql ]]; then
    "${PSQL[@]}" -U "$MIGRATION_ROLE" -d "$DB" -v ON_ERROR_STOP=1 \
      -f "$TEST_DIR/fixtures/pre_migration_431_acl_probe.sql" \
      >> "$LOG_DIR/migration-replay.log" 2>&1
  fi
  source_file="$MIGRATIONS/$f"
  if [[ "$f" == 20260906040154_nabuuma_v1_7_demand_intelligence.sql ]]; then
    source_file="$TEST_DIR/replay_overrides/$f"
  fi
  if "${PSQL[@]}" -U "$MIGRATION_ROLE" -d "$DB" -v ON_ERROR_STOP=1 \
    -v VERBOSITY=verbose -f "$source_file" >> "$LOG_DIR/migration-replay.log" 2>&1; then
    :
  else
    rc=$?
    printf '\nSTOP: file=%s exit=%s\n' "$f" "$rc" | tee -a "$LOG_DIR/migration-replay.log"
    exit "$rc"
  fi
done
echo 'ALL_73_MIGRATIONS_APPLIED_WITH_ONE_DOCUMENTED_TEST_OVERRIDE' \
  | tee -a "$LOG_DIR/migration-replay.log"

"${PSQL[@]}" -U "$MIGRATION_ROLE" -d "$DB" -v ON_ERROR_STOP=1 \
  -f "$TEST_DIR/fixtures/v3_15_7_audit_source.sql" \
  > "$LOG_DIR/audit-source-fixture.log" 2>&1
: > "$LOG_DIR/final-sql-acceptance.log"
run_test() {
  local name="$1"
  shift
  printf '\n=== %s ===\n' "$name" | tee -a "$LOG_DIR/final-sql-acceptance.log"
  if "$@" >> "$LOG_DIR/final-sql-acceptance.log" 2>&1; then
    echo "PASS $name" | tee -a "$LOG_DIR/final-sql-acceptance.log"
  else
    local rc=$?
    echo "FAIL $name SQL_EXIT=$rc" | tee -a "$LOG_DIR/final-sql-acceptance.log"
    exit "$rc"
  fi
}

run_test ACL_RECONCILIATION "${PSQL[@]}" -U "$MIGRATION_ROLE" -d "$DB" -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -f "$REPO/supabase/tests/acl_reconciliation_assertions.sql"
run_test CUSTOM_ACCESS_TOKEN_HOOK "${PSQL[@]}" -U "$MIGRATION_ROLE" -d "$DB" -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -f "$REPO/supabase/tests/custom_access_token_hook_assertions.sql"
run_test RECIPE_PUBLISHING "${PSQL[@]}" -U "$MIGRATION_ROLE" -d "$DB" -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -f "$REPO/supabase/tests/recipe_publishing_assertions.sql"
run_test SCHEMA_RECONCILIATION "${PSQL[@]}" -U "$MIGRATION_ROLE" -d "$DB" -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -f "$REPO/supabase/tests/schema_reconciliation_assertions.sql"
run_test SETTLEMENT_EXECUTION "${PSQL[@]}" -U "$MIGRATION_ROLE" -d "$DB" -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -f "$REPO/supabase/tests/settlement_execution_assertions.sql"
run_test V3_15_7_AUDIT_LOGS "${PSQL[@]}" -U "$MIGRATION_ROLE" -d "$DB" -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -c 'BEGIN;' -f "$TEST_DIR/fixtures/v3_15_7_audit_log_tenants.sql" -f "$TEST_DIR/fixtures/v3_15_7_audit_source.sql" -f "$REPO/supabase/tests/v3_15_7_audit_logs_assertions.sql" -c 'ROLLBACK;'
run_test RLS_CATALOG_MATRIX "${PSQL[@]}" -U "$MIGRATION_ROLE" -d "$DB" -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -f "$TEST_DIR/rls_catalog_acceptance.sql"
run_test RLS_RUNTIME_CORE_MATRIX "${PSQL[@]}" -U "$MIGRATION_ROLE" -d "$DB" -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -f "$TEST_DIR/auth_rls_core_acceptance.sql"
echo 'FINAL_SQL_ACCEPTANCE_FAILURES=0' | tee -a "$LOG_DIR/final-sql-acceptance.log"
