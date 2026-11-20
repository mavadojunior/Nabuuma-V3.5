\set ON_ERROR_STOP on

DO $schema_assertions$
DECLARE
    v_recipe_fk_count integer;
    v_balance_trigger_count integer;
    v_trigger_count integer;
    v_search_path text;
    v_function_name text;
    v_public_view record;
BEGIN
    SELECT count(*)
      INTO v_recipe_fk_count
      FROM pg_catalog.pg_constraint c
     WHERE c.conrelid = 'public.recipe_versions'::regclass
       AND c.conname = 'recipe_versions_product_id_fkey'
       AND c.contype = 'f'
       AND pg_catalog.pg_get_constraintdef(c.oid) =
           'FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE';

    IF v_recipe_fk_count <> 1 THEN
        RAISE EXCEPTION 'Expected the recovered recipe_versions.product_id FK';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM pg_catalog.pg_constraint c
         WHERE c.conrelid = 'public.recipe_versions'::regclass
           AND c.conname = 'recipe_versions_id_fkey'
    ) THEN
        RAISE EXCEPTION 'Production-only recipe_versions.id FK remains';
    END IF;

    SELECT count(*)
      INTO v_balance_trigger_count
      FROM pg_catalog.pg_trigger t
     WHERE t.tgrelid = 'public.financial_ledger_entries'::regclass
       AND t.tgname = 'financial_ledger_transaction_balance_ct'
       AND NOT t.tgisinternal;

    IF v_balance_trigger_count <> 1 THEN
        RAISE EXCEPTION 'Deferred financial ledger balance trigger missing';
    END IF;

    SELECT count(*) INTO v_trigger_count
    FROM pg_catalog.pg_trigger t
    WHERE t.tgrelid = 'public.recipe_versions'::regclass
      AND t.tgname = 'recipe_versions_same_business'
      AND t.tgfoid = 'public.enforce_same_business()'::regprocedure
      AND NOT t.tgisinternal;
    IF v_trigger_count <> 1 THEN
        RAISE EXCEPTION 'Recipe same-business integrity trigger is missing';
    END IF;

    SELECT count(*) INTO v_trigger_count
    FROM pg_catalog.pg_trigger t
    WHERE t.tgrelid = 'public.ingredient_prices'::regclass
      AND t.tgname = 'ingredient_prices_same_business'
      AND t.tgfoid = 'public.enforce_price_supplier_business()'::regprocedure
      AND NOT t.tgisinternal;
    IF v_trigger_count <> 1 THEN
        RAISE EXCEPTION 'Ingredient-price same-business integrity trigger is missing';
    END IF;

    SELECT count(*) INTO v_trigger_count
    FROM pg_catalog.pg_trigger t
    WHERE t.tgrelid = 'public.recipe_versions'::regclass
      AND t.tgname = 'recipe_immutable'
      AND t.tgfoid = 'public.prevent_published_recipe_change()'::regprocedure
      AND NOT t.tgisinternal;
    IF v_trigger_count <> 1 THEN
        RAISE EXCEPTION 'Published-recipe immutability trigger is missing';
    END IF;

    FOREACH v_function_name IN ARRAY ARRAY[
        'v21_audit_allocation_insert',
        'v22_audit_milestone',
        'enforce_same_business',
        'enforce_price_supplier_business'
    ] LOOP
        SELECT p.proconfig[array_position(p.proconfig, 'search_path=pg_catalog')]
          INTO v_search_path
          FROM pg_catalog.pg_proc p
          JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname = v_function_name
           AND p.pronargs = 0
           AND p.prosecdef;

        IF v_search_path IS DISTINCT FROM 'search_path=pg_catalog' THEN
            RAISE EXCEPTION '% is missing SECURITY DEFINER search_path hardening',
                v_function_name;
        END IF;
    END LOOP;

    SELECT p.proconfig[array_position(p.proconfig, 'search_path=pg_catalog')]
      INTO v_search_path
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'prevent_published_recipe_change'
       AND p.pronargs = 0
       AND NOT p.prosecdef;

    IF v_search_path IS DISTINCT FROM 'search_path=pg_catalog' THEN
        RAISE EXCEPTION 'prevent_published_recipe_change search_path is not hardened';
    END IF;

    IF pg_catalog.has_function_privilege(
        'anon', 'public.enforce_same_business()', 'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
        'authenticated', 'public.enforce_same_business()', 'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
        'service_role', 'public.enforce_same_business()', 'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
        'anon', 'public.enforce_price_supplier_business()', 'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
        'authenticated', 'public.enforce_price_supplier_business()', 'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
        'service_role', 'public.enforce_price_supplier_business()', 'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'tenant-integrity trigger functions are executable by API roles';
    END IF;

    IF NOT pg_catalog.has_table_privilege('anon', 'public.recipe_costs', 'SELECT')
       OR NOT pg_catalog.has_table_privilege('authenticated', 'public.recipe_costs', 'SELECT')
       OR NOT pg_catalog.has_table_privilege('service_role', 'public.recipe_costs', 'SELECT')
       OR pg_catalog.has_table_privilege('anon', 'public.recipe_costs', 'INSERT')
       OR pg_catalog.has_table_privilege('anon', 'public.recipe_costs', 'UPDATE')
       OR pg_catalog.has_table_privilege('anon', 'public.recipe_costs', 'DELETE')
       OR pg_catalog.has_table_privilege('authenticated', 'public.recipe_costs', 'INSERT')
       OR pg_catalog.has_table_privilege('authenticated', 'public.recipe_costs', 'UPDATE')
       OR pg_catalog.has_table_privilege('authenticated', 'public.recipe_costs', 'DELETE')
       OR pg_catalog.has_table_privilege('service_role', 'public.recipe_costs', 'INSERT')
       OR pg_catalog.has_table_privilege('service_role', 'public.recipe_costs', 'UPDATE')
       OR pg_catalog.has_table_privilege('service_role', 'public.recipe_costs', 'DELETE') THEN
        RAISE EXCEPTION 'recipe_costs must grant SELECT only to API roles';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM pg_catalog.pg_proc p
          JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname IN ('v21_audit_allocation_insert','v22_audit_milestone')
           AND p.prosecdef
           AND COALESCE(p.proconfig, ARRAY[]::text[]) @> ARRAY['search_path=public']
    ) THEN
        RAISE EXCEPTION 'Legacy SECURITY DEFINER search_path=public remains';
    END IF;

    SELECT p.proconfig[array_position(p.proconfig, 'search_path=pg_catalog, pg_temp')]
      INTO v_search_path
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'publish_recipe'
       AND p.pronargs = 1
       AND p.prosecdef;

    IF v_search_path IS DISTINCT FROM 'search_path=pg_catalog, pg_temp' THEN
        RAISE EXCEPTION 'publish_recipe is missing a controlled SECURITY DEFINER search_path';
    END IF;

    FOR v_public_view IN
        SELECT c.relname, c.reloptions
          FROM pg_catalog.pg_class c
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public'
           AND c.relkind = 'v'
    LOOP
        IF NOT COALESCE(
            v_public_view.reloptions @> ARRAY['security_invoker=true'],
            false
        ) THEN
            RAISE EXCEPTION 'public view % is not security-invoker', v_public_view.relname;
        END IF;
    END LOOP;
END
$schema_assertions$;

SELECT 'PASS: structural reconciliation and SECURITY DEFINER search paths verified' AS result;
