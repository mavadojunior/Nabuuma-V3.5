#!/usr/bin/env bash
set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
TEST_USER_ID="d7bce5e8-9bca-4dd9-bdb8-000000000091"
TMP_DIR="$(mktemp -d)"

cleanup() {
  psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 >/dev/null <<SQL || true
DROP TRIGGER IF EXISTS __nabuuma_test_delay_business_insert ON public.businesses;
DROP FUNCTION IF EXISTS public.__nabuuma_test_delay_business_insert();
DELETE FROM public.businesses
WHERE id IN (
  SELECT business_id FROM public.business_members
  WHERE user_id = '$TEST_USER_ID'::uuid
);
DELETE FROM auth.users WHERE id = '$TEST_USER_ID'::uuid;
SQL
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 >/dev/null <<SQL
DROP TRIGGER IF EXISTS __nabuuma_test_delay_business_insert ON public.businesses;
DROP FUNCTION IF EXISTS public.__nabuuma_test_delay_business_insert();
DELETE FROM public.businesses
WHERE id IN (
  SELECT business_id FROM public.business_members
  WHERE user_id = '$TEST_USER_ID'::uuid
);
DELETE FROM auth.users WHERE id = '$TEST_USER_ID'::uuid;
INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) VALUES (
  '$TEST_USER_ID', 'authenticated', 'authenticated',
  'create-business-race@example.invalid', '',
  pg_catalog.now(), '{}'::jsonb, '{}'::jsonb,
  pg_catalog.now(), pg_catalog.now()
);
CREATE OR REPLACE FUNCTION public.__nabuuma_test_delay_business_insert()
RETURNS trigger
LANGUAGE plpgsql
AS \$function\$
BEGIN
  PERFORM pg_catalog.pg_sleep(1.25);
  RETURN NEW;
END;
\$function\$;
CREATE TRIGGER __nabuuma_test_delay_business_insert
BEFORE INSERT ON public.businesses
FOR EACH ROW
EXECUTE FUNCTION public.__nabuuma_test_delay_business_insert();
SQL

run_create() {
  local label="$1"
  local business_name="$2"
  psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 >"$TMP_DIR/$label.out" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', '$TEST_USER_ID', true
) AS claim_sub \\gset
SELECT pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"$TEST_USER_ID","role":"authenticated","aud":"authenticated"}',
  true
) AS claims \\gset
SELECT public.create_business('$business_name') ->> 'business_id';
COMMIT;
SQL
}

run_create first "Concurrent onboarding A" &
first_pid=$!
sleep 0.1
run_create second "Concurrent onboarding B" &
second_pid=$!

first_status=0
second_status=0
wait "$first_pid" || first_status=$?
wait "$second_pid" || second_status=$?
if [[ "$first_status" -ne 0 || "$second_status" -ne 0 ]]; then
  echo "FAIL: one or both concurrent create_business calls failed"
  cat "$TMP_DIR/first.out" "$TMP_DIR/second.out"
  exit 1
fi

first_id="$(tail -n 1 "$TMP_DIR/first.out")"
second_id="$(tail -n 1 "$TMP_DIR/second.out")"
if [[ -z "$first_id" || "$first_id" != "$second_id" ]]; then
  echo "FAIL: concurrent onboarding returned different business IDs"
  cat "$TMP_DIR/first.out" "$TMP_DIR/second.out"
  exit 1
fi

psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 >/dev/null <<SQL
DO \$assert\$
BEGIN
  IF (
    SELECT count(*) FROM public.business_members
    WHERE user_id = '$TEST_USER_ID'::uuid
  ) <> 1 THEN
    RAISE EXCEPTION 'concurrent onboarding created more than one membership';
  END IF;

  IF (
    SELECT count(*)
    FROM public.businesses b
    JOIN public.business_members bm ON bm.business_id = b.id
    WHERE bm.user_id = '$TEST_USER_ID'::uuid
  ) <> 1 THEN
    RAISE EXCEPTION 'concurrent onboarding created more than one business';
  END IF;

  IF (
    SELECT count(*)
    FROM public.subscriptions s
    JOIN public.business_members bm ON bm.business_id = s.business_id
    WHERE bm.user_id = '$TEST_USER_ID'::uuid
  ) <> 1 THEN
    RAISE EXCEPTION 'concurrent onboarding created an incorrect subscription count';
  END IF;
END
\$assert\$;
SQL

echo "PASS: concurrent create_business calls resolve to one business ($first_id)"
