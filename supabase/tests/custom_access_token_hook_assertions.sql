\set ON_ERROR_STOP on

-- Runtime contract tests for the private organisation-claims hook.
-- All fixture rows are rolled back; this test is for the disposable local stack.
BEGIN;

INSERT INTO auth.users (
    id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
) VALUES
  ('d7bce5e8-9bca-4dd9-bdb8-000000000001', 'authenticated', 'authenticated',
   'hook-contract-1@example.invalid', '', pg_catalog.now(), '{}'::jsonb, '{}'::jsonb,
   pg_catalog.now(), pg_catalog.now()),
  ('d7bce5e8-9bca-4dd9-bdb8-000000000002', 'authenticated', 'authenticated',
   'hook-contract-2@example.invalid', '', pg_catalog.now(), '{}'::jsonb, '{}'::jsonb,
   pg_catalog.now(), pg_catalog.now());

INSERT INTO nabuuma.organisations (id, name)
VALUES ('d7bce5e8-9bca-4dd9-bdb8-000000000003', 'Hook contract test organisation');

INSERT INTO nabuuma.organisation_memberships (
    organisation_id, user_id, role, is_active
) VALUES (
    'd7bce5e8-9bca-4dd9-bdb8-000000000003',
    'd7bce5e8-9bca-4dd9-bdb8-000000000001',
    'ORGANISATION_OWNER', true
);

DO $hook_assertions$
DECLARE
    v_user_id uuid := 'd7bce5e8-9bca-4dd9-bdb8-000000000001';
    v_unassigned_user_id uuid := 'd7bce5e8-9bca-4dd9-bdb8-000000000002';
    v_organisation_id uuid := 'd7bce5e8-9bca-4dd9-bdb8-000000000003';
    v_result jsonb;
BEGIN
    IF NOT pg_catalog.has_schema_privilege('supabase_auth_admin', 'nabuuma', 'USAGE') THEN
        RAISE EXCEPTION 'supabase_auth_admin lacks USAGE on nabuuma';
    END IF;

    IF NOT pg_catalog.has_function_privilege(
        'supabase_auth_admin',
        'nabuuma.custom_access_token_hook(jsonb)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'supabase_auth_admin cannot execute the access-token hook';
    END IF;

    IF pg_catalog.has_function_privilege(
        'anon', 'nabuuma.custom_access_token_hook(jsonb)', 'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
        'authenticated', 'nabuuma.custom_access_token_hook(jsonb)', 'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
        'service_role', 'nabuuma.custom_access_token_hook(jsonb)', 'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'access-token hook is executable by an API role';
    END IF;

    IF NOT pg_catalog.has_function_privilege(
        'service_role', 'public.network_execute_settlement_route(uuid)', 'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
        'anon', 'public.network_execute_settlement_route(uuid)', 'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
        'authenticated', 'public.network_execute_settlement_route(uuid)', 'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'settlement executor grants do not match the service-only contract';
    END IF;

    -- The trusted database owner reaches the function body; NULL must fail
    -- before any route lookup or financial mutation can occur.
    BEGIN
        PERFORM public.network_execute_settlement_route(NULL::uuid);
        RAISE EXCEPTION 'settlement executor accepted a NULL route id' USING ERRCODE = 'XX000';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        NULL;
    END;

    v_result := nabuuma.custom_access_token_hook(
        pg_catalog.jsonb_build_object(
            'user_id', v_user_id::text,
            'claims', '{"aud":"authenticated","role":"authenticated"}'::jsonb
        )
    );

    IF v_result #>> '{claims,organisation_id}' <> v_organisation_id::text THEN
        RAISE EXCEPTION 'hook did not add the active organisation claim';
    END IF;

    IF v_result #> '{claims,roles}' <> '["ORGANISATION_OWNER"]'::jsonb THEN
        RAISE EXCEPTION 'hook did not add the active membership role claim';
    END IF;

    -- An existing Auth user without an active organisation must be rejected.
    BEGIN
        PERFORM nabuuma.custom_access_token_hook(
            pg_catalog.jsonb_build_object(
                'user_id', v_unassigned_user_id::text,
                'claims', '{}'::jsonb
            )
        );
        RAISE EXCEPTION 'hook accepted a user without an active organisation' USING ERRCODE = 'XX000';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        NULL;
    END;

    -- A malformed UUID and a missing claims object are input errors.
    BEGIN
        PERFORM nabuuma.custom_access_token_hook(
            '{"user_id":"not-a-uuid","claims":{}}'::jsonb
        );
        RAISE EXCEPTION 'hook accepted a malformed user id';
    EXCEPTION WHEN SQLSTATE '22023' THEN
        NULL;
    END;

    BEGIN
        PERFORM nabuuma.custom_access_token_hook(
            pg_catalog.jsonb_build_object('user_id', v_user_id::text)
        );
        RAISE EXCEPTION 'hook accepted an event without claims';
    EXCEPTION WHEN SQLSTATE '22023' THEN
        NULL;
    END;

    -- A syntactically valid but unprovisioned Auth subject must be rejected.
    BEGIN
        PERFORM nabuuma.custom_access_token_hook(
            pg_catalog.jsonb_build_object(
                'user_id', 'd7bce5e8-9bca-4dd9-bdb8-000000000099',
                'claims', '{}'::jsonb
            )
        );
        RAISE EXCEPTION 'hook accepted an unprovisioned Auth subject' USING ERRCODE = 'XX000';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        NULL;
    END;
END
$hook_assertions$;

ROLLBACK;

SELECT 'PASS: access-token hook runtime contract verified' AS result;
