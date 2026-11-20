\set ON_ERROR_STOP on

-- Runtime contract for tenant-authorized recipe publication and immutability.
-- Fixtures are isolated in a transaction and rolled back.
BEGIN;

INSERT INTO auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) VALUES
  ('f1bce5e8-9bca-4dd9-bdb8-000000000001', 'authenticated', 'authenticated',
   'recipe-owner@example.invalid', '', pg_catalog.now(), '{}'::jsonb, '{}'::jsonb,
   pg_catalog.now(), pg_catalog.now()),
  ('f1bce5e8-9bca-4dd9-bdb8-000000000002', 'authenticated', 'authenticated',
   'recipe-outsider@example.invalid', '', pg_catalog.now(), '{}'::jsonb, '{}'::jsonb,
   pg_catalog.now(), pg_catalog.now());

INSERT INTO public.businesses (id, name) VALUES
  ('f1bce5e8-9bca-4dd9-bdb8-000000000003', 'Recipe publication business A'),
  ('f1bce5e8-9bca-4dd9-bdb8-000000000004', 'Recipe publication business B');

INSERT INTO public.business_members (business_id, user_id, role) VALUES
  ('f1bce5e8-9bca-4dd9-bdb8-000000000003',
   'f1bce5e8-9bca-4dd9-bdb8-000000000001', 'owner'),
  ('f1bce5e8-9bca-4dd9-bdb8-000000000004',
   'f1bce5e8-9bca-4dd9-bdb8-000000000002', 'owner');

INSERT INTO public.products (id, business_id, code, name) VALUES
  ('f1bce5e8-9bca-4dd9-bdb8-000000000005',
   'f1bce5e8-9bca-4dd9-bdb8-000000000003', 'RECIPE-A', 'Recipe product A'),
  ('f1bce5e8-9bca-4dd9-bdb8-000000000006',
   'f1bce5e8-9bca-4dd9-bdb8-000000000004', 'RECIPE-B', 'Recipe product B');

INSERT INTO public.recipe_versions (
    id, business_id, product_id, version_number, status, method, created_by
) VALUES
  ('f1bce5e8-9bca-4dd9-bdb8-000000000007',
   'f1bce5e8-9bca-4dd9-bdb8-000000000003',
   'f1bce5e8-9bca-4dd9-bdb8-000000000005', 1, 'draft', 'First recipe',
   'f1bce5e8-9bca-4dd9-bdb8-000000000001'),
  ('f1bce5e8-9bca-4dd9-bdb8-000000000008',
   'f1bce5e8-9bca-4dd9-bdb8-000000000003',
   'f1bce5e8-9bca-4dd9-bdb8-000000000005', 2, 'draft', 'Second recipe',
   'f1bce5e8-9bca-4dd9-bdb8-000000000001'),
  ('f1bce5e8-9bca-4dd9-bdb8-000000000009',
   'f1bce5e8-9bca-4dd9-bdb8-000000000003',
   'f1bce5e8-9bca-4dd9-bdb8-000000000005', 3, 'draft', 'Disposable draft',
   'f1bce5e8-9bca-4dd9-bdb8-000000000001'),
  ('f1bce5e8-9bca-4dd9-bdb8-000000000010',
   'f1bce5e8-9bca-4dd9-bdb8-000000000003',
   'f1bce5e8-9bca-4dd9-bdb8-000000000005', 4, 'draft', 'Unauthorized target',
   'f1bce5e8-9bca-4dd9-bdb8-000000000001'),
  ('f1bce5e8-9bca-4dd9-bdb8-000000000012',
   'f1bce5e8-9bca-4dd9-bdb8-000000000004',
   'f1bce5e8-9bca-4dd9-bdb8-000000000006', 1, 'draft', 'Other business recipe',
   'f1bce5e8-9bca-4dd9-bdb8-000000000002');

DO $recipe_privilege_assertions$
BEGIN
    IF NOT pg_catalog.has_function_privilege(
        'service_role', 'public.publish_recipe(uuid)', 'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'service_role cannot execute publish_recipe';
    END IF;

    IF pg_catalog.has_function_privilege(
        'anon', 'public.publish_recipe(uuid)', 'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
        'authenticated', 'public.publish_recipe(uuid)', 'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'publish_recipe is exposed outside the trusted service-role contract';
    END IF;
END
$recipe_privilege_assertions$;

-- The existing same-business trigger must reject cross-tenant recipe links.
DO $cross_business_assertions$
DECLARE
    v_error text;
BEGIN
    BEGIN
        INSERT INTO public.recipe_versions (
            id, business_id, product_id, version_number, status, method
        ) VALUES (
            'f1bce5e8-9bca-4dd9-bdb8-000000000011',
            'f1bce5e8-9bca-4dd9-bdb8-000000000003',
            'f1bce5e8-9bca-4dd9-bdb8-000000000006',
            1, 'draft', 'Cross-business attempt'
        );
        RAISE EXCEPTION 'cross-business recipe reference was accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Cross-business reference rejected' THEN
            RAISE;
        END IF;
    END;
END
$cross_business_assertions$;

SET LOCAL ROLE service_role;
SELECT pg_catalog.set_config(
    'request.jwt.claim.sub',
    'f1bce5e8-9bca-4dd9-bdb8-000000000001',
    true
) AS claim_sub \gset
SELECT pg_catalog.set_config(
    'request.jwt.claims',
    '{"sub":"f1bce5e8-9bca-4dd9-bdb8-000000000001","role":"authenticated","aud":"authenticated"}',
    true
) AS claims \gset

-- First publication succeeds.
SELECT public.publish_recipe('f1bce5e8-9bca-4dd9-bdb8-000000000007');

DO $first_publish_assertions$
BEGIN
    IF (
        SELECT status FROM public.recipe_versions
        WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000007'
    ) <> 'published' THEN
        RAISE EXCEPTION 'first recipe version was not published';
    END IF;

    IF (
        SELECT active_recipe_version_id FROM public.products
        WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000005'
    ) <> 'f1bce5e8-9bca-4dd9-bdb8-000000000007'::uuid THEN
        RAISE EXCEPTION 'product active recipe pointer was not updated';
    END IF;
END
$first_publish_assertions$;

-- Publishing a replacement archives the old version and updates the pointer.
SELECT public.publish_recipe('f1bce5e8-9bca-4dd9-bdb8-000000000008');

DO $replacement_publish_assertions$
BEGIN
    IF (
        SELECT status FROM public.recipe_versions
        WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000007'
    ) <> 'archived' THEN
        RAISE EXCEPTION 'previous published recipe was not archived';
    END IF;

    IF (
        SELECT status FROM public.recipe_versions
        WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000008'
    ) <> 'published' THEN
        RAISE EXCEPTION 'replacement recipe was not published';
    END IF;

    IF (
        SELECT active_recipe_version_id FROM public.products
        WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000005'
    ) <> 'f1bce5e8-9bca-4dd9-bdb8-000000000008'::uuid THEN
        RAISE EXCEPTION 'product pointer does not reference the replacement recipe';
    END IF;
END
$replacement_publish_assertions$;

-- A second tenant can publish its own recipe through the trusted server RPC.
SELECT pg_catalog.set_config(
    'request.jwt.claim.sub',
    'f1bce5e8-9bca-4dd9-bdb8-000000000002',
    true
) AS business_b_sub \gset
SELECT pg_catalog.set_config(
    'request.jwt.claims',
    '{"sub":"f1bce5e8-9bca-4dd9-bdb8-000000000002","role":"authenticated","aud":"authenticated"}',
    true
) AS business_b_claims \gset
SELECT public.publish_recipe('f1bce5e8-9bca-4dd9-bdb8-000000000012');

DO $business_b_publish_assertions$
BEGIN
    IF (
        SELECT active_recipe_version_id FROM public.products
        WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000006'
    ) IS DISTINCT FROM 'f1bce5e8-9bca-4dd9-bdb8-000000000012'::uuid THEN
        RAISE EXCEPTION 'business B product active recipe pointer was not updated';
    END IF;
END
$business_b_publish_assertions$;

-- Restore business A's authenticated client context for pointer and immutability checks.
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
    'request.jwt.claim.sub',
    'f1bce5e8-9bca-4dd9-bdb8-000000000001',
    true
) AS business_a_sub \gset
SELECT pg_catalog.set_config(
    'request.jwt.claims',
    '{"sub":"f1bce5e8-9bca-4dd9-bdb8-000000000001","role":"authenticated","aud":"authenticated"}',
    true
) AS business_a_claims \gset

-- The active recipe pointer cannot cross business/product boundaries or point
-- to a draft version, even when the caller can update the owning product.
DO $active_recipe_pointer_assertions$
DECLARE
    v_error text;
BEGIN
    BEGIN
        UPDATE public.products
        SET active_recipe_version_id = 'f1bce5e8-9bca-4dd9-bdb8-000000000012'
        WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000005';
        RAISE EXCEPTION 'cross-business active recipe pointer was accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Active recipe version must be published and belong to this product' THEN
            RAISE;
        END IF;
    END;

    BEGIN
        UPDATE public.products
        SET active_recipe_version_id = 'f1bce5e8-9bca-4dd9-bdb8-000000000009'
        WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000005';
        RAISE EXCEPTION 'draft active recipe pointer was accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Active recipe version must be published and belong to this product' THEN
            RAISE;
        END IF;
    END;

    IF (
        SELECT active_recipe_version_id FROM public.products
        WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000005'
    ) IS DISTINCT FROM 'f1bce5e8-9bca-4dd9-bdb8-000000000008'::uuid THEN
        RAISE EXCEPTION 'rejected pointer changes altered the active recipe';
    END IF;
END
$active_recipe_pointer_assertions$;

-- A client cannot insert a recipe directly in the published state.
DO $direct_published_insert_assertions$
DECLARE
    v_error text;
BEGIN
    BEGIN
        INSERT INTO public.recipe_versions (
            id, business_id, product_id, version_number, status, method, created_by
        ) VALUES (
            'f1bce5e8-9bca-4dd9-bdb8-000000000013',
            'f1bce5e8-9bca-4dd9-bdb8-000000000003',
            'f1bce5e8-9bca-4dd9-bdb8-000000000005',
            5, 'published', 'Direct publication attempt',
            'f1bce5e8-9bca-4dd9-bdb8-000000000001'
        );
        RAISE EXCEPTION 'direct published recipe insert was accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Use publish_recipe() to publish recipes' THEN
            RAISE;
        END IF;
    END;
END
$direct_published_insert_assertions$;

-- Direct client updates, deletes, and archived-to-published transitions remain blocked.
DO $recipe_immutability_assertions$
DECLARE
    v_error text;
BEGIN
    BEGIN
        UPDATE public.recipe_versions
        SET method = 'unauthorized edit'
        WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000008';
        RAISE EXCEPTION 'published recipe update was accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Published recipe versions are immutable' THEN
            RAISE;
        END IF;
    END;

    BEGIN
        DELETE FROM public.recipe_versions
        WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000008';
        RAISE EXCEPTION 'published recipe deletion was accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Published recipe versions are immutable' THEN
            RAISE;
        END IF;
    END;

    BEGIN
        UPDATE public.recipe_versions
        SET status = 'published'
        WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000007';
        RAISE EXCEPTION 'direct archived-to-published transition was accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Use publish_recipe() to publish recipes' THEN
            RAISE;
        END IF;
    END;
END
$recipe_immutability_assertions$;

-- A user without membership cannot publish another business's recipe.
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT pg_catalog.set_config(
    'request.jwt.claim.sub',
    'f1bce5e8-9bca-4dd9-bdb8-000000000002',
    true
) AS outsider_sub \gset
SELECT pg_catalog.set_config(
    'request.jwt.claims',
    '{"sub":"f1bce5e8-9bca-4dd9-bdb8-000000000002","role":"authenticated","aud":"authenticated"}',
    true
) AS outsider_claims \gset

DO $unauthorized_publish_assertions$
DECLARE
    v_error text;
BEGIN
    BEGIN
        PERFORM public.publish_recipe(
            'f1bce5e8-9bca-4dd9-bdb8-000000000010'
        );
        RAISE EXCEPTION 'non-member published another business recipe';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Not permitted' THEN
            RAISE;
        END IF;
    END;
END
$unauthorized_publish_assertions$;

-- Deleting an unpublished draft is allowed; published versions remain immutable.
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
    'request.jwt.claim.sub',
    'f1bce5e8-9bca-4dd9-bdb8-000000000001',
    true
) AS owner_sub \gset
SELECT pg_catalog.set_config(
    'request.jwt.claims',
    '{"sub":"f1bce5e8-9bca-4dd9-bdb8-000000000001","role":"authenticated","aud":"authenticated"}',
    true
) AS owner_claims \gset

DELETE FROM public.recipe_versions
WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000009';

DO $draft_delete_assertions$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.recipe_versions
        WHERE id = 'f1bce5e8-9bca-4dd9-bdb8-000000000009'
    ) THEN
        RAISE EXCEPTION 'unpublished draft deletion was unexpectedly blocked';
    END IF;
END
$draft_delete_assertions$;

ROLLBACK;

SELECT 'PASS: recipe publication authorization, replacement, tenant boundary, and immutability verified' AS result;
