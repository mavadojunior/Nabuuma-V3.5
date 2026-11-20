-- Reconcile production objects that were created outside the 69-row
-- supabase_migrations history. Definitions are recovered from pg_get_functiondef
-- and pg_catalog on 2026-11-14. No production table rows are copied.
BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';
SET LOCAL search_path = pg_catalog, public, extensions, auth;

-- ---------------------------------------------------------------------------
-- Private organisation schema. These tables are owner-only in production.
-- The two existing production rows are intentionally not seeded here.
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS nabuuma;
ALTER SCHEMA nabuuma OWNER TO postgres;

CREATE TABLE IF NOT EXISTS nabuuma.organisations (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT organisations_pkey PRIMARY KEY (id),
    CONSTRAINT organisations_name_not_blank CHECK (btrim(name) <> '')
);
ALTER TABLE nabuuma.organisations OWNER TO postgres;

CREATE TABLE IF NOT EXISTS nabuuma.organisation_memberships (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    organisation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role text NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT organisation_memberships_pkey PRIMARY KEY (id),
    CONSTRAINT organisation_memberships_organisation_id_fkey
        FOREIGN KEY (organisation_id)
        REFERENCES nabuuma.organisations(id) ON DELETE CASCADE,
    CONSTRAINT organisation_memberships_user_id_fkey
        FOREIGN KEY (user_id)
        REFERENCES auth.users(id) ON DELETE CASCADE,
    CONSTRAINT organisation_memberships_role_valid
        CHECK (role = ANY (ARRAY[
            'LEARNER'::text,
            'PROFESSIONAL'::text,
            'TRAINER'::text,
            'ORGANISATION_MANAGER'::text,
            'ORGANISATION_OWNER'::text,
            'PLATFORM_ADMIN'::text
        ])),
    CONSTRAINT organisation_memberships_user_unique
        UNIQUE (organisation_id, user_id)
);
ALTER TABLE nabuuma.organisation_memberships OWNER TO postgres;

CREATE INDEX IF NOT EXISTS organisation_memberships_active_user_idx
    ON nabuuma.organisation_memberships USING btree (user_id, organisation_id)
    WHERE is_active;

CREATE UNIQUE INDEX IF NOT EXISTS organisation_memberships_one_active_user_idx
    ON nabuuma.organisation_memberships USING btree (user_id)
    WHERE is_active;

ALTER TABLE nabuuma.organisations ENABLE ROW LEVEL SECURITY;
ALTER TABLE nabuuma.organisations NO FORCE ROW LEVEL SECURITY;
ALTER TABLE nabuuma.organisation_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE nabuuma.organisation_memberships NO FORCE ROW LEVEL SECURITY;

REVOKE ALL PRIVILEGES ON SCHEMA nabuuma FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL PRIVILEGES ON TABLE
    nabuuma.organisations,
    nabuuma.organisation_memberships
FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Public todos starter table. It is empty in production, so only its schema,
-- ACLs, and owner-scoped RLS policy are restored.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.todos (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    task text NOT NULL,
    user_id uuid NOT NULL REFERENCES auth.users(id),
    completed boolean DEFAULT false,
    CONSTRAINT todos_pkey PRIMARY KEY (id)
);
ALTER TABLE public.todos OWNER TO postgres;
ALTER TABLE public.todos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.todos NO FORCE ROW LEVEL SECURITY;

REVOKE ALL PRIVILEGES ON TABLE public.todos
FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.todos TO authenticated;
GRANT ALL PRIVILEGES ON TABLE public.todos TO service_role;

DROP POLICY IF EXISTS "Users can only access their own todos" ON public.todos;
CREATE POLICY "Users can only access their own todos"
ON public.todos
FOR ALL
TO authenticated
USING ((SELECT auth.uid()) = user_id)
WITH CHECK ((SELECT auth.uid()) = user_id);

-- ---------------------------------------------------------------------------
-- Production audit trigger functions.
-- audit_purchase_order_status_change is preserved as an existing legacy
-- function; production currently has no trigger attached to it.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.audit_purchase_order_row_change_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  v_old jsonb := NULL;
  v_new jsonb := NULL;
  v_row jsonb;
  v_business_id uuid;
  v_entity_id uuid;
  v_action text;
  v_entity_type text;
  v_metadata jsonb;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD IS NOT DISTINCT FROM NEW THEN
    RETURN NEW;
  END IF;

  IF TG_OP <> 'INSERT' THEN
    v_old := to_jsonb(OLD);
  END IF;
  IF TG_OP <> 'DELETE' THEN
    v_new := to_jsonb(NEW);
  END IF;

  v_row := coalesce(v_new, v_old);
  v_business_id := (v_row ->> 'business_id')::uuid;
  v_entity_id := (v_row ->> 'id')::uuid;
  v_action := lower(TG_OP);
  v_entity_type := TG_TABLE_NAME;
  v_metadata := jsonb_build_object('old', v_old, 'new', v_new);

  -- Keep table-specific OLD/NEW field access inside a nested branch.
  -- SQL boolean expressions may reorder AND operands, so a flat guard can
  -- evaluate OLD.status for other tables that do not have that column.
  IF TG_TABLE_NAME = 'purchase_orders' AND TG_OP = 'UPDATE' THEN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
      v_action := 'purchase_order_status_changed';
      v_entity_type := 'purchase_order';
      v_metadata := jsonb_build_object(
        'old_status', OLD.status::text,
        'new_status', NEW.status::text,
        'order_number', NEW.order_number,
        'old', v_old,
        'new', v_new
      );
    END IF;
  END IF;

  INSERT INTO public.audit_logs (
    business_id, user_id, action, entity_type, entity_id, metadata
  ) VALUES (
    v_business_id,
    auth.uid(),
    v_action,
    v_entity_type,
    v_entity_id,
    v_metadata
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$function$
;
ALTER FUNCTION public.audit_purchase_order_row_change_v1() OWNER TO postgres;

CREATE OR REPLACE FUNCTION public.audit_purchase_order_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
  INSERT INTO public.audit_logs (
    business_id,
    user_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  VALUES (
    NEW.business_id,
    auth.uid(),
    'purchase_order_status_changed',
    'purchase_order',
    NEW.id,
    jsonb_build_object(
      'old_status', OLD.status::text,
      'new_status', NEW.status::text,
      'order_number', NEW.order_number
    )
  );

  RETURN NEW;
END;
$function$
;
ALTER FUNCTION public.audit_purchase_order_status_change() OWNER TO postgres;

DROP TRIGGER IF EXISTS audit_goods_receipt_lines_row_change_v1 ON public.goods_receipt_lines;
CREATE TRIGGER audit_goods_receipt_lines_row_change_v1
AFTER INSERT OR DELETE OR UPDATE ON public.goods_receipt_lines
FOR EACH ROW EXECUTE FUNCTION public.audit_purchase_order_row_change_v1();

DROP TRIGGER IF EXISTS audit_goods_receipts_row_change_v1 ON public.goods_receipts;
CREATE TRIGGER audit_goods_receipts_row_change_v1
AFTER INSERT OR DELETE OR UPDATE ON public.goods_receipts
FOR EACH ROW EXECUTE FUNCTION public.audit_purchase_order_row_change_v1();

DROP TRIGGER IF EXISTS audit_purchase_order_lines_row_change_v1 ON public.purchase_order_lines;
CREATE TRIGGER audit_purchase_order_lines_row_change_v1
AFTER INSERT OR DELETE OR UPDATE ON public.purchase_order_lines
FOR EACH ROW EXECUTE FUNCTION public.audit_purchase_order_row_change_v1();

DROP TRIGGER IF EXISTS audit_purchase_orders_row_change_v1 ON public.purchase_orders;
CREATE TRIGGER audit_purchase_orders_row_change_v1
AFTER INSERT OR DELETE OR UPDATE ON public.purchase_orders
FOR EACH ROW EXECUTE FUNCTION public.audit_purchase_order_row_change_v1();

-- ---------------------------------------------------------------------------
-- Trusted financial settlement RPC. Preserve the production SECURITY DEFINER
-- body and its service_role-only EXECUTE boundary.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.network_execute_settlement_route(p_route_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
    v_route public.network_settlement_routes%ROWTYPE;
    v_gate public.network_financial_finality_gates%ROWTYPE;
    v_batch public.settlement_batches%ROWTYPE;

    v_reserved_minor bigint;
    v_consumed_minor bigint;
    v_principal_minor bigint;

    v_previous_hash text;
    v_event_hash text;
    v_now timestamptz := now();

    r record;
BEGIN
    --------------------------------------------------------------------------
    -- SECURITY BOUNDARY
    --------------------------------------------------------------------------

    IF NOT public.v32_is_trusted_executor() THEN
        RAISE EXCEPTION 'trusted executor required';
    END IF;

    IF p_route_id IS NULL THEN
        RAISE EXCEPTION 'route id is required';
    END IF;

    --------------------------------------------------------------------------
    -- ROUTE SERIALIZATION
    --
    -- This prevents two workers from executing the same route concurrently.
    --------------------------------------------------------------------------

    PERFORM pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            'nabuuma:v311:settlement-execution:' || p_route_id::text,
            0
        )
    );

    SELECT *
    INTO v_route
    FROM public.network_settlement_routes
    WHERE route_id = p_route_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'settlement route not found: %', p_route_id;
    END IF;

    --------------------------------------------------------------------------
    -- IDEMPOTENT TERMINAL STATE
    --------------------------------------------------------------------------

    IF v_route.state = 'completed' THEN
        IF NOT EXISTS (
            SELECT 1
            FROM public.settlement_batches b
            WHERE b.id = v_route.settlement_batch_id
              AND b.state = 'reconciled'
        ) THEN
            RAISE EXCEPTION
                'completed route has non-reconciled settlement batch';
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM public.network_financial_finality_gates g
            WHERE g.gate_id = (
                SELECT gate_id
                FROM public.network_financial_finality_gates
                WHERE settlement_batch_id = v_route.settlement_batch_id
                  AND route_id = v_route.route_id
            )
              AND g.state = 'consumed'
        ) THEN
            RAISE EXCEPTION
                'completed route has non-consumed finality gate';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM public.network_liquidity_reservations reservation_row
            WHERE reservation_row.route_id = v_route.route_id
              AND reservation_row.state <> 'consumed'
        ) THEN
            RAISE EXCEPTION
                'completed route has unconsumed liquidity reservations';
        END IF;

        RETURN v_route.route_id;
    END IF;

    --------------------------------------------------------------------------
    -- AUTHORIZATION STATE
    --------------------------------------------------------------------------

    IF v_route.state <> 'authorized' THEN
        RAISE EXCEPTION
            'settlement route must be authorized before execution; current state=%',
            v_route.state;
    END IF;

    --------------------------------------------------------------------------
    -- LOCK THE SETTLEMENT BATCH
    --------------------------------------------------------------------------

    SELECT *
    INTO v_batch
    FROM public.settlement_batches
    WHERE id = v_route.settlement_batch_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'settlement batch not found for route %',
            p_route_id;
    END IF;

    IF v_batch.buyer_business_id <> v_route.buyer_business_id
       OR v_batch.seller_business_id <> v_route.seller_business_id
       OR v_batch.currency <> v_route.currency
       OR v_batch.total_minor <> v_route.principal_minor
    THEN
        RAISE EXCEPTION
            'settlement route does not match settlement batch';
    END IF;

    v_principal_minor := v_route.principal_minor;

    IF v_principal_minor <= 0 THEN
        RAISE EXCEPTION 'settlement route principal must be positive';
    END IF;

    --------------------------------------------------------------------------
    -- FINALITY GATE
    --
    -- The gate must belong to this exact batch and route.
    -- We re-evaluate it immediately before execution so expired/missing
    -- evidence cannot remain silently usable.
    --------------------------------------------------------------------------

    SELECT *
    INTO v_gate
    FROM public.network_financial_finality_gates
    WHERE settlement_batch_id = v_route.settlement_batch_id
      AND route_id = v_route.route_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'financial finality gate not found for settlement route %',
            p_route_id;
    END IF;

    IF v_gate.state = 'consumed' THEN
        RAISE EXCEPTION
            'financial finality gate has already been consumed';
    END IF;

    PERFORM public.network_evaluate_financial_finality_gate(
        v_gate.gate_id
    );

    SELECT *
    INTO v_gate
    FROM public.network_financial_finality_gates
    WHERE gate_id = v_gate.gate_id
    FOR UPDATE;

    IF v_gate.state <> 'verified' THEN
        RAISE EXCEPTION
            'financial finality gate is not verified: %',
            v_gate.blocking_reason;
    END IF;

    --------------------------------------------------------------------------
    -- LIQUIDITY RESERVATION INTEGRITY
    --
    -- The route must have reservations covering exactly the principal.
    -- No partial execution is permitted.
    --------------------------------------------------------------------------

    SELECT
        COALESCE(SUM(amount_minor) FILTER (WHERE state = 'reserved'), 0),
        COALESCE(SUM(amount_minor) FILTER (WHERE state = 'consumed'), 0)
    INTO
        v_reserved_minor,
        v_consumed_minor
    FROM public.network_liquidity_reservations
    WHERE route_id = v_route.route_id;

    IF v_reserved_minor <> v_principal_minor THEN
        RAISE EXCEPTION
            'liquidity reservation mismatch: reserved %, required %',
            v_reserved_minor,
            v_principal_minor;
    END IF;

    IF v_consumed_minor <> 0 THEN
        RAISE EXCEPTION
            'route has previously consumed liquidity reservations';
    END IF;

    --------------------------------------------------------------------------
    -- ROUTE-LEG / RESERVATION INTEGRITY
    --
    -- The compiled route must conserve the exact principal across both
    -- routing legs and liquidity reservations.
    --------------------------------------------------------------------------

    IF (
        SELECT COALESCE(SUM(amount_minor), 0)
        FROM public.network_settlement_route_legs
        WHERE route_id = v_route.route_id
    ) <> v_principal_minor THEN
        RAISE EXCEPTION
            'settlement route legs do not equal route principal';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.network_settlement_route_legs l
        FULL OUTER JOIN public.network_liquidity_reservations res
          ON res.route_id = l.route_id
         AND res.liquidity_source_id = l.liquidity_source_id
        WHERE COALESCE(l.route_id, res.route_id) = v_route.route_id
          AND (
              l.route_leg_id IS NULL
              OR res.reservation_id IS NULL
              OR l.amount_minor <> res.amount_minor
              OR l.currency <> v_route.currency
          )
    ) THEN
        RAISE EXCEPTION
            'settlement route legs and liquidity reservations do not match';
    END IF;

    --------------------------------------------------------------------------
    -- LOCK ALL RESERVATIONS AND THEIR LIQUIDITY SOURCES
    --------------------------------------------------------------------------

    FOR r IN
        SELECT
            lr.reservation_id,
            lr.liquidity_source_id,
            lr.amount_minor,
            lr.state,
            s.reserved_minor,
            s.capacity_minor,
            s.status AS source_status,
            s.currency AS source_currency,
            s.business_id AS source_business_id
        FROM public.network_liquidity_reservations lr
        JOIN public.network_liquidity_sources s
          ON s.liquidity_source_id = lr.liquidity_source_id
        WHERE lr.route_id = v_route.route_id
        ORDER BY lr.liquidity_source_id
        FOR UPDATE OF lr, s
    LOOP
        IF r.state <> 'reserved' THEN
            RAISE EXCEPTION
                'liquidity reservation % is not reserved',
                r.reservation_id;
        END IF;

        IF r.amount_minor <= 0 THEN
            RAISE EXCEPTION
                'invalid liquidity reservation amount';
        END IF;

        IF r.source_currency <> v_route.currency THEN
            RAISE EXCEPTION
                'liquidity source currency mismatch';
        END IF;

        IF r.source_business_id <> v_route.buyer_business_id THEN
            RAISE EXCEPTION
                'liquidity source does not belong to settlement buyer';
        END IF;

        IF r.source_status <> 'active' THEN
            RAISE EXCEPTION
                'liquidity source % is not active',
                r.liquidity_source_id;
        END IF;

        IF r.reserved_minor < r.amount_minor THEN
            RAISE EXCEPTION
                'liquidity source reservation accounting is inconsistent';
        END IF;
    END LOOP;

    --------------------------------------------------------------------------
    -- ENTER EXECUTING STATE
    --------------------------------------------------------------------------

    UPDATE public.network_settlement_routes
    SET
        state = 'executing',
        updated_at = v_now
    WHERE route_id = v_route.route_id
      AND state = 'authorized';

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'failed to transition settlement route into executing state';
    END IF;

    --------------------------------------------------------------------------
    -- EXECUTION START EVENT
    --------------------------------------------------------------------------

    SELECT event_hash
    INTO v_previous_hash
    FROM public.network_settlement_routing_events
    WHERE route_id = v_route.route_id
    ORDER BY created_at DESC, event_id DESC
    LIMIT 1;

    v_event_hash := encode(
        extensions.digest(
            convert_to(
                v_route.route_id::text
                || ':execution_started:'
                || coalesce(v_previous_hash, ''),
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    );

    INSERT INTO public.network_settlement_routing_events (
        route_id,
        event_type,
        payload,
        previous_hash,
        event_hash,
        created_by
    )
    VALUES (
        v_route.route_id,
        'execution_started',
        jsonb_build_object(
            'settlement_batch_id', v_route.settlement_batch_id,
            'principal_minor', v_route.principal_minor,
            'currency', v_route.currency
        ),
        v_previous_hash,
        v_event_hash,
        auth.uid()
    );

    --------------------------------------------------------------------------
    -- CANONICAL FINANCIAL EXECUTION
    --
    -- This is the only point at which financial ledger mutations occur.
    -- The V3.2 function performs:
    --
    --   invoice settlement
    --   buyer/seller postings
    --   escrow movement
    --   balance updates
    --   ledger hashing
    --   ledger balance enforcement
    --
    --------------------------------------------------------------------------

    PERFORM public.clear_v32_settlement_batch(
        v_route.settlement_batch_id
    );

    --------------------------------------------------------------------------
    -- CONSUME LIQUIDITY
    --------------------------------------------------------------------------

    FOR r IN
        SELECT
            lr.reservation_id,
            lr.liquidity_source_id,
            lr.amount_minor
        FROM public.network_liquidity_reservations lr
        WHERE lr.route_id = v_route.route_id
          AND lr.state = 'reserved'
        ORDER BY lr.liquidity_source_id
        FOR UPDATE
    LOOP
        UPDATE public.network_liquidity_sources
        SET
            reserved_minor = reserved_minor - r.amount_minor,
            updated_at = v_now
        WHERE liquidity_source_id = r.liquidity_source_id
          AND reserved_minor >= r.amount_minor;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'failed to consume liquidity source reservation %',
                r.liquidity_source_id;
        END IF;

        UPDATE public.network_liquidity_reservations
        SET
            state = 'consumed',
            consumed_at = v_now
        WHERE reservation_id = r.reservation_id
          AND state = 'reserved';

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'failed to consume liquidity reservation %',
                r.reservation_id;
        END IF;
    END LOOP;

    --------------------------------------------------------------------------
    -- FINALITY GATE CONSUMPTION
    --------------------------------------------------------------------------

    IF NOT public.network_consume_financial_finality_gate(
        v_gate.gate_id
    ) THEN
        RAISE EXCEPTION
            'financial finality gate was not consumed';
    END IF;

    --------------------------------------------------------------------------
    -- COMPLETE ROUTE
    --------------------------------------------------------------------------

    UPDATE public.network_settlement_routes
    SET
        state = 'completed',
        completed_at = v_now,
        updated_at = v_now
    WHERE route_id = v_route.route_id
      AND state = 'executing';

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'failed to complete settlement route';
    END IF;

    --------------------------------------------------------------------------
    -- EXECUTION COMPLETED EVENT
    --------------------------------------------------------------------------

    SELECT event_hash
    INTO v_previous_hash
    FROM public.network_settlement_routing_events
    WHERE route_id = v_route.route_id
    ORDER BY created_at DESC, event_id DESC
    LIMIT 1;

    v_event_hash := encode(
        extensions.digest(
            convert_to(
                v_route.route_id::text
                || ':execution_completed:'
                || coalesce(v_previous_hash, ''),
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    );

    INSERT INTO public.network_settlement_routing_events (
        route_id,
        event_type,
        payload,
        previous_hash,
        event_hash,
        created_by
    )
    VALUES (
        v_route.route_id,
        'execution_completed',
        jsonb_build_object(
            'settlement_batch_id', v_route.settlement_batch_id,
            'principal_minor', v_route.principal_minor,
            'currency', v_route.currency
        ),
        v_previous_hash,
        v_event_hash,
        auth.uid()
    );

    RETURN v_route.route_id;
END;
$function$
;
ALTER FUNCTION public.network_execute_settlement_route(uuid) OWNER TO postgres;
REVOKE ALL PRIVILEGES ON FUNCTION public.network_execute_settlement_route(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.network_execute_settlement_route(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- DDL event trigger: automatically enable RLS on newly created public tables.
-- Install last so this migration's own table creation has explicit handling.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on % (SQLSTATE %, error %)',
            cmd.object_identity, SQLSTATE, SQLERRM;
          RAISE;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$
;
ALTER FUNCTION public.rls_auto_enable() OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.rls_auto_enable() TO service_role;

DROP EVENT TRIGGER IF EXISTS ensure_rls;
CREATE EVENT TRIGGER ensure_rls
ON ddl_command_end
WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
EXECUTE FUNCTION public.rls_auto_enable();
ALTER EVENT TRIGGER ensure_rls ENABLE;

-- ---------------------------------------------------------------------------
-- Additional production objects absent from the 69-row migration ledger.
-- Definitions, trigger properties, owners and ACL boundaries were read from
-- pg_catalog on 2026-11-14. These are schema objects only; no rows are copied.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION nabuuma.custom_access_token_hook(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
    auth_user_id uuid;
    membership_count bigint;
    resolved_organisation_id uuid;
    resolved_role text;
    claims jsonb;
BEGIN
    IF event IS NULL
       OR jsonb_typeof(event) <> 'object'
       OR nullif(event ->> 'user_id', '') IS NULL
    THEN
        RAISE EXCEPTION
            'Authentication subject is required'
            USING errcode = '22023';
    END IF;

    BEGIN
        auth_user_id := (event ->> 'user_id')::uuid;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION
                'Invalid authentication subject'
                USING errcode = '22023';
    END;

    claims := event -> 'claims';

    IF claims IS NULL OR jsonb_typeof(claims) <> 'object' THEN
        RAISE EXCEPTION 'Authentication claims are invalid' USING errcode = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM auth.users AS auth_user WHERE auth_user.id = auth_user_id
    ) THEN
        RAISE EXCEPTION 'Authentication subject is not provisioned' USING errcode = 'P0001';
    END IF;

    SELECT count(*) INTO membership_count
    FROM nabuuma.organisation_memberships AS membership
    WHERE membership.user_id = auth_user_id AND membership.is_active = true;

    IF membership_count = 0 THEN
        RAISE EXCEPTION 'Authenticated user has no active organisation' USING errcode = 'P0001';
    END IF;
    IF membership_count <> 1 THEN
        RAISE EXCEPTION 'Authenticated user has ambiguous active organisations' USING errcode = 'P0001';
    END IF;

    SELECT membership.organisation_id, membership.role
    INTO STRICT resolved_organisation_id, resolved_role
    FROM nabuuma.organisation_memberships AS membership
    WHERE membership.user_id = auth_user_id AND membership.is_active = true;

    claims := jsonb_set(claims, '{organisation_id}', to_jsonb(resolved_organisation_id::text), true);
    claims := jsonb_set(claims, '{roles}', jsonb_build_array(resolved_role), true);
    RETURN jsonb_build_object('claims', claims);
END;
$function$;
ALTER FUNCTION nabuuma.custom_access_token_hook(jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION nabuuma.custom_access_token_hook(jsonb)
FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA nabuuma TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION nabuuma.custom_access_token_hook(jsonb) TO supabase_auth_admin;

CREATE OR REPLACE FUNCTION public.publish_recipe(p_recipe uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO pg_catalog, pg_temp
AS $function$
DECLARE
    r public.recipe_versions%ROWTYPE;
BEGIN
    SELECT * INTO r
      FROM public.recipe_versions
     WHERE id = p_recipe;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Not permitted';
    END IF;

    IF NOT public.has_role(
        r.business_id,
        ARRAY['owner','manager','trainer']::public.member_role[]
    ) THEN
        RAISE EXCEPTION 'Not permitted';
    END IF;

    UPDATE public.recipe_versions
       SET status = 'archived'
     WHERE product_id = r.product_id
       AND status = 'published'
       AND id <> r.id;

    UPDATE public.recipe_versions
       SET status = 'published',
           published_at = pg_catalog.now()
     WHERE id = r.id;

    UPDATE public.products
       SET active_recipe_version_id = r.id
     WHERE id = r.product_id;
END
$function$;
ALTER FUNCTION public.publish_recipe(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.publish_recipe(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_recipe(uuid) TO service_role;

CREATE OR REPLACE VIEW public.recipe_costs WITH (security_invoker=true) AS
SELECT
    rv.id AS recipe_version_id,
    rv.business_id,
    rv.product_id,
    COALESCE(
        sum(ri.quantity * (ip.purchase_price / ip.purchase_quantity) / ip.usable_yield_fraction),
        0::numeric
    ) AS ingredient_cost
FROM recipe_versions rv
LEFT JOIN recipe_ingredients ri ON ri.recipe_version_id = rv.id
LEFT JOIN LATERAL (
    SELECT x.id, x.business_id, x.ingredient_id, x.supplier_id,
           x.purchase_quantity, x.purchase_price, x.usable_yield_fraction,
           x.effective_from
    FROM ingredient_prices x
    WHERE x.ingredient_id = ri.ingredient_id
      AND x.business_id = rv.business_id
    ORDER BY x.effective_from DESC
    LIMIT 1
) ip ON true
GROUP BY rv.id, rv.business_id, rv.product_id;
ALTER VIEW public.recipe_costs OWNER TO postgres;
REVOKE ALL PRIVILEGES ON TABLE public.recipe_costs FROM anon, authenticated, service_role;
GRANT SELECT ON TABLE public.recipe_costs TO anon, authenticated, service_role;

DROP TRIGGER IF EXISTS financial_ledger_transaction_balance_ct ON public.financial_ledger_entries;
CREATE CONSTRAINT TRIGGER financial_ledger_transaction_balance_ct
AFTER INSERT ON public.financial_ledger_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION public.v32_assert_ledger_transaction_balanced();

DROP TRIGGER IF EXISTS network_ledger_forensic_events_no_truncate ON public.network_ledger_forensic_events;
CREATE TRIGGER network_ledger_forensic_events_no_truncate
BEFORE TRUNCATE ON public.network_ledger_forensic_events
FOR EACH STATEMENT EXECUTE FUNCTION public.v311_forensic_event_guard();

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Remaining catalog drift recovered from production pg_catalog.
-- This reconciles indexes, constraints, policy expressions and exact function
-- bodies/configuration/EXECUTE ACLs that changed outside the 69-row ledger.
-- ---------------------------------------------------------------------------
-- The composite unique key is redundant with financial_ledger_entries_pkey(id).
-- Keep the non-unique (transaction_id,id) lookup index recorded in history.
-- Refuse to remove either object if its definition differs from the known
-- replay-only key or if the replacement lookup index is missing.
DO $ledger_index_preflight$
DECLARE
    v_constraint_definition text;
    v_index_definition text;
BEGIN
    SELECT pg_catalog.pg_get_constraintdef(c.oid, true)
      INTO v_constraint_definition
      FROM pg_catalog.pg_constraint AS c
     WHERE c.conrelid = 'public.financial_ledger_entries'::regclass
       AND c.conname = 'financial_ledger_entries_transaction_id_id_key';

    IF v_constraint_definition IS NOT NULL
       AND v_constraint_definition <> 'UNIQUE (transaction_id, id)' THEN
        RAISE EXCEPTION 'Unexpected financial ledger composite constraint: %', v_constraint_definition;
    END IF;

    SELECT pg_catalog.pg_get_indexdef(c.oid)
      INTO v_index_definition
      FROM pg_catalog.pg_class AS c
      JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname = 'financial_ledger_entries_transaction_id_id_key';

    IF v_index_definition IS NOT NULL
       AND (position('UNIQUE INDEX' IN v_index_definition) = 0
            OR position('USING btree (transaction_id, id)' IN v_index_definition) = 0) THEN
        RAISE EXCEPTION 'Unexpected financial ledger composite index: %', v_index_definition;
    END IF;

    IF pg_catalog.to_regclass('public.financial_ledger_entries_transaction_idx') IS NULL THEN
        RAISE EXCEPTION 'Cannot remove composite unique key without the retained transaction lookup index';
    END IF;
END;
$ledger_index_preflight$;

ALTER TABLE "public"."financial_ledger_entries" DROP CONSTRAINT IF EXISTS "financial_ledger_entries_transaction_id_id_key";

-- Production had an FK from recipe_versions.id to products.id. That conflicts
-- with the repository's versioned model: product_id identifies the parent and
-- multiple recipe_versions may exist for one product. Replace the live FK with
-- the original product_id relationship. Fail closed on unexpected definitions
-- or orphan data instead of silently dropping an unknown constraint.
DO $recipe_version_fk$
DECLARE
    v_definition text;
    v_orphans bigint;
BEGIN
    SELECT pg_catalog.pg_get_constraintdef(c.oid, true)
      INTO v_definition
      FROM pg_catalog.pg_constraint AS c
     WHERE c.conrelid = 'public.recipe_versions'::regclass
       AND c.conname = 'recipe_versions_id_fkey';

    IF v_definition IS NOT NULL
       AND v_definition <> 'FOREIGN KEY (id) REFERENCES products(id) ON DELETE CASCADE' THEN
        RAISE EXCEPTION 'Unexpected recipe_versions_id_fkey definition: %', v_definition;
    END IF;

    SELECT pg_catalog.pg_get_constraintdef(c.oid, true)
      INTO v_definition
      FROM pg_catalog.pg_constraint AS c
     WHERE c.conrelid = 'public.recipe_versions'::regclass
       AND c.conname = 'recipe_versions_product_id_fkey';

    IF v_definition IS NOT NULL
       AND v_definition <> 'FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE' THEN
        RAISE EXCEPTION 'Unexpected recipe_versions_product_id_fkey definition: %', v_definition;
    END IF;

    SELECT count(*)
      INTO v_orphans
      FROM public.recipe_versions AS rv
      LEFT JOIN public.products AS p ON p.id = rv.product_id
     WHERE p.id IS NULL;

    IF v_orphans > 0 THEN
        RAISE EXCEPTION 'Cannot restore recipe_versions.product_id FK: % orphan rows', v_orphans;
    END IF;

    IF v_definition IS NULL THEN
        ALTER TABLE public.recipe_versions
            ADD CONSTRAINT recipe_versions_product_id_fkey
            FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint AS c
         WHERE c.conrelid = 'public.recipe_versions'::regclass
           AND c.conname = 'recipe_versions_id_fkey'
    ) THEN
        ALTER TABLE public.recipe_versions DROP CONSTRAINT recipe_versions_id_fkey;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint AS c
         WHERE c.conrelid = 'public.recipe_versions'::regclass
           AND c.conname = 'recipe_versions_product_id_fkey'
           AND pg_catalog.pg_get_constraintdef(c.oid, true) =
               'FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE'
    ) THEN
        RAISE EXCEPTION 'Expected recipe_versions.product_id foreign key was not installed';
    END IF;
END;
$recipe_version_fk$;

DO $financial_index_preflight$
DECLARE
    v_definition text;
BEGIN
    SELECT pg_catalog.pg_get_indexdef(c.oid)
      INTO v_definition
      FROM pg_catalog.pg_class AS c
      JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname = 'dispatch_financial_clearance_batch_idx';

    IF v_definition IS NOT NULL
       AND position('ON public.network_dispatch_financial_clearances USING btree (settlement_batch_id)' IN v_definition) = 0 THEN
        RAISE EXCEPTION 'Unexpected duplicate clearance index definition: %', v_definition;
    END IF;

    IF v_definition IS NOT NULL
       AND pg_catalog.to_regclass('public.network_dispatch_financial_clearances_settlement_idx') IS NULL THEN
        RAISE EXCEPTION 'Cannot remove legacy clearance index without its replacement';
    END IF;
END;
$financial_index_preflight$;

DO $constraint$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conname='network_ledger_forensic_events_event_hash_sha256_check' AND conrelid=pg_catalog.to_regclass('public.network_ledger_forensic_events')) THEN ALTER TABLE "public"."network_ledger_forensic_events" ADD CONSTRAINT "network_ledger_forensic_events_event_hash_sha256_check" CHECK (event_hash ~ '^[0-9a-fA-F]{64}$'::text); END IF; END $constraint$;
DO $constraint$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conname='network_ledger_forensic_events_previous_hash_sha256_check' AND conrelid=pg_catalog.to_regclass('public.network_ledger_forensic_events')) THEN ALTER TABLE "public"."network_ledger_forensic_events" ADD CONSTRAINT "network_ledger_forensic_events_previous_hash_sha256_check" CHECK (previous_hash IS NULL OR previous_hash ~ '^[0-9a-fA-F]{64}$'::text); END IF; END $constraint$;
DROP INDEX IF EXISTS "public"."financial_ledger_entries_transaction_id_id_key";
DROP INDEX IF EXISTS "public"."dispatch_financial_clearance_batch_idx";
CREATE INDEX IF NOT EXISTS goods_receipt_lines_business_id_goods_receipt_id_idx ON public.goods_receipt_lines USING btree (business_id, goods_receipt_id);
CREATE INDEX IF NOT EXISTS goods_receipt_lines_ingredient_id_idx ON public.goods_receipt_lines USING btree (ingredient_id);
CREATE INDEX IF NOT EXISTS goods_receipt_lines_purchase_order_line_id_idx ON public.goods_receipt_lines USING btree (purchase_order_line_id);
CREATE INDEX IF NOT EXISTS goods_receipts_purchase_order_id_idx ON public.goods_receipts USING btree (purchase_order_id);
CREATE INDEX IF NOT EXISTS purchase_order_lines_business_id_purchase_order_id_idx ON public.purchase_order_lines USING btree (business_id, purchase_order_id);
CREATE INDEX IF NOT EXISTS purchase_order_lines_ingredient_id_idx ON public.purchase_order_lines USING btree (ingredient_id);
CREATE INDEX IF NOT EXISTS purchase_orders_purchase_plan_id_idx ON public.purchase_orders USING btree (purchase_plan_id);
CREATE INDEX IF NOT EXISTS purchase_orders_supplier_id_idx ON public.purchase_orders USING btree (supplier_id);
CREATE INDEX IF NOT EXISTS recipe_ingredients_ingredient_id_idx ON public.recipe_ingredients USING btree (ingredient_id);
CREATE INDEX IF NOT EXISTS recipe_ingredients_recipe_version_id_idx ON public.recipe_ingredients USING btree (recipe_version_id);
CREATE INDEX IF NOT EXISTS staff_profiles_business_id_idx ON public.staff_profiles USING btree (business_id);
CREATE INDEX IF NOT EXISTS suppliers_business_id_idx ON public.suppliers USING btree (business_id);
DROP POLICY IF EXISTS "reject_all_public_access" ON "public"."audit_logs";
DROP POLICY IF EXISTS "inventory_write" ON "public"."inventory_movements";
DROP POLICY IF EXISTS "audit_write" ON "public"."audit_logs";
CREATE POLICY "audit_write" ON "public"."audit_logs" AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK ((is_member(business_id) AND (user_id = ( SELECT auth.uid() AS uid))));
DROP POLICY IF EXISTS "network_audit_member_select" ON "public"."network_audit_stream";
CREATE POLICY "network_audit_member_select" ON "public"."network_audit_stream" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE (((bm.business_id = network_audit_stream.buyer_business_id) OR (bm.business_id = network_audit_stream.seller_business_id)) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_contract_line_member_select" ON "public"."network_contract_lines";
CREATE POLICY "network_contract_line_member_select" ON "public"."network_contract_lines" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE (((bm.business_id = network_contract_lines.buyer_business_id) OR (bm.business_id = network_contract_lines.seller_business_id)) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_negotiation_line_member_select" ON "public"."network_contract_negotiation_lines";
CREATE POLICY "network_negotiation_line_member_select" ON "public"."network_contract_negotiation_lines" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ((network_contract_negotiations n
     JOIN network_contracts c ON ((c.id = n.contract_id)))
     JOIN business_members bm ON (((bm.business_id = c.buyer_business_id) OR (bm.business_id = c.seller_business_id))))
  WHERE ((n.id = network_contract_negotiation_lines.negotiation_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_negotiation_member_select" ON "public"."network_contract_negotiations";
CREATE POLICY "network_negotiation_member_select" ON "public"."network_contract_negotiations" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (network_contracts c
     JOIN business_members bm ON (((bm.business_id = c.buyer_business_id) OR (bm.business_id = c.seller_business_id))))
  WHERE ((c.id = network_contract_negotiations.contract_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_signature_member_select" ON "public"."network_contract_signatures";
CREATE POLICY "network_signature_member_select" ON "public"."network_contract_signatures" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = network_contract_signatures.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_contract_member_select" ON "public"."network_contracts";
CREATE POLICY "network_contract_member_select" ON "public"."network_contracts" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = network_contracts.buyer_business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))) OR (EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = network_contracts.seller_business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid)))))));
DROP POLICY IF EXISTS "network_receipt_member_select" ON "public"."network_dispatched_receipts";
CREATE POLICY "network_receipt_member_select" ON "public"."network_dispatched_receipts" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE (((bm.business_id = network_dispatched_receipts.buyer_business_id) OR (bm.business_id = network_dispatched_receipts.seller_business_id)) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_dispute_member_select" ON "public"."network_dispatches_disputes";
CREATE POLICY "network_dispute_member_select" ON "public"."network_dispatches_disputes" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (network_order_dispatches d
     JOIN business_members bm ON (((bm.business_id = d.buyer_business_id) OR (bm.business_id = d.seller_business_id))))
  WHERE ((d.id = network_dispatches_disputes.dispatch_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_key_rotation_member_select" ON "public"."network_key_rotation_logs";
CREATE POLICY "network_key_rotation_member_select" ON "public"."network_key_rotation_logs" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = network_key_rotation_logs.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_liquidity_reservations_member_select" ON "public"."network_liquidity_reservations";
CREATE POLICY "network_liquidity_reservations_member_select" ON "public"."network_liquidity_reservations" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (network_settlement_routes r
     JOIN business_members bm ON (((bm.business_id = r.buyer_business_id) OR (bm.business_id = r.seller_business_id))))
  WHERE ((r.route_id = network_liquidity_reservations.route_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_liquidity_sources_member_select" ON "public"."network_liquidity_sources";
CREATE POLICY "network_liquidity_sources_member_select" ON "public"."network_liquidity_sources" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = network_liquidity_sources.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_dispatch_line_member_select" ON "public"."network_order_dispatch_lines";
CREATE POLICY "network_dispatch_line_member_select" ON "public"."network_order_dispatch_lines" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE (((bm.business_id = network_order_dispatch_lines.buyer_business_id) OR (bm.business_id = network_order_dispatch_lines.seller_business_id)) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_dispatch_member_select" ON "public"."network_order_dispatches";
CREATE POLICY "network_dispatch_member_select" ON "public"."network_order_dispatches" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE (((bm.business_id = network_order_dispatches.buyer_business_id) OR (bm.business_id = network_order_dispatches.seller_business_id)) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_verification_member_select" ON "public"."network_organization_verifications";
CREATE POLICY "network_verification_member_select" ON "public"."network_organization_verifications" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (network_organizations o
     JOIN business_members bm ON ((bm.business_id = o.business_id)))
  WHERE ((o.id = network_organization_verifications.organization_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_org_member_select" ON "public"."network_organizations";
CREATE POLICY "network_org_member_select" ON "public"."network_organizations" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = network_organizations.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_order_line_member_select" ON "public"."network_sales_order_lines";
CREATE POLICY "network_order_line_member_select" ON "public"."network_sales_order_lines" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE (((bm.business_id = network_sales_order_lines.buyer_business_id) OR (bm.business_id = network_sales_order_lines.seller_business_id)) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_order_member_select" ON "public"."network_sales_orders";
CREATE POLICY "network_order_member_select" ON "public"."network_sales_orders" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE (((bm.business_id = network_sales_orders.buyer_business_id) OR (bm.business_id = network_sales_orders.seller_business_id)) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_settlement_route_legs_member_select" ON "public"."network_settlement_route_legs";
CREATE POLICY "network_settlement_route_legs_member_select" ON "public"."network_settlement_route_legs" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (network_settlement_routes r
     JOIN business_members bm ON (((bm.business_id = r.buyer_business_id) OR (bm.business_id = r.seller_business_id))))
  WHERE ((r.route_id = network_settlement_route_legs.route_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_settlement_routes_member_select" ON "public"."network_settlement_routes";
CREATE POLICY "network_settlement_routes_member_select" ON "public"."network_settlement_routes" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = network_settlement_routes.buyer_business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))) OR (EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = network_settlement_routes.seller_business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid)))))));
DROP POLICY IF EXISTS "network_settlement_routing_events_member_select" ON "public"."network_settlement_routing_events";
CREATE POLICY "network_settlement_routing_events_member_select" ON "public"."network_settlement_routing_events" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (network_settlement_routes r
     JOIN business_members bm ON (((bm.business_id = r.buyer_business_id) OR (bm.business_id = r.seller_business_id))))
  WHERE ((r.route_id = network_settlement_routing_events.route_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "network_tenant_keys_member_select" ON "public"."network_tenant_keys";
CREATE POLICY "network_tenant_keys_member_select" ON "public"."network_tenant_keys" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = network_tenant_keys.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "v22_milestone_select" ON "public"."v22_logistics_milestones";
CREATE POLICY "v22_milestone_select" ON "public"."v22_logistics_milestones" AS PERMISSIVE FOR SELECT TO "authenticated" USING (is_member(business_id));
DROP POLICY IF EXISTS "v22_shipment_select" ON "public"."v22_logistics_shipments";
CREATE POLICY "v22_shipment_select" ON "public"."v22_logistics_shipments" AS PERMISSIVE FOR SELECT TO "authenticated" USING (is_member(business_id));
DROP POLICY IF EXISTS "v29_learning_member_select" ON "public"."v29_learning_outcomes";
CREATE POLICY "v29_learning_member_select" ON "public"."v29_learning_outcomes" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = v29_learning_outcomes.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "v29_candidates_member_select" ON "public"."v29_policy_candidates";
CREATE POLICY "v29_candidates_member_select" ON "public"."v29_policy_candidates" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = v29_policy_candidates.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
DROP POLICY IF EXISTS "v29_evaluations_member_select" ON "public"."v29_policy_evaluations";
CREATE POLICY "v29_evaluations_member_select" ON "public"."v29_policy_evaluations" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = v29_policy_evaluations.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid))))));
CREATE OR REPLACE FUNCTION nabuuma.custom_access_token_hook(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
    auth_user_id uuid;
    membership_count bigint;
    resolved_organisation_id uuid;
    resolved_role text;
    claims jsonb;
BEGIN
    IF event IS NULL
       OR jsonb_typeof(event) <> 'object'
       OR nullif(event ->> 'user_id', '') IS NULL
    THEN
        RAISE EXCEPTION
            'Authentication subject is required'
            USING errcode = '22023';
    END IF;

    BEGIN
        auth_user_id := (event ->> 'user_id')::uuid;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION
                'Invalid authentication subject'
                USING errcode = '22023';
    END;

    claims := event -> 'claims';

    IF claims IS NULL
       OR jsonb_typeof(claims) <> 'object'
    THEN
        RAISE EXCEPTION
            'Authentication claims are invalid'
            USING errcode = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM auth.users AS auth_user
        WHERE auth_user.id = auth_user_id
    )
    THEN
        RAISE EXCEPTION
            'Authentication subject is not provisioned'
            USING errcode = 'P0001';
    END IF;

    SELECT count(*)
    INTO membership_count
    FROM nabuuma.organisation_memberships AS membership
    WHERE membership.user_id = auth_user_id
      AND membership.is_active = true;

    IF membership_count = 0 THEN
        RAISE EXCEPTION
            'Authenticated user has no active organisation'
            USING errcode = 'P0001';
    END IF;

    IF membership_count <> 1 THEN
        RAISE EXCEPTION
            'Authenticated user has ambiguous active organisations'
            USING errcode = 'P0001';
    END IF;

    SELECT
        membership.organisation_id,
        membership.role
    INTO STRICT
        resolved_organisation_id,
        resolved_role
    FROM nabuuma.organisation_memberships AS membership
    WHERE membership.user_id = auth_user_id
      AND membership.is_active = true;

    claims := jsonb_set(
        claims,
        '{organisation_id}',
        to_jsonb(resolved_organisation_id::text),
        true
    );

    claims := jsonb_set(
        claims,
        '{roles}',
        jsonb_build_array(resolved_role),
        true
    );

    RETURN jsonb_build_object(
        'claims',
        claims
    );
END;
$function$;
ALTER FUNCTION nabuuma.custom_access_token_hook(jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION nabuuma.custom_access_token_hook(jsonb) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION nabuuma.custom_access_token_hook(jsonb) TO "supabase_auth_admin";
CREATE OR REPLACE FUNCTION public.create_business(business_name text, currency_code text DEFAULT 'AED'::text, timezone_name text DEFAULT 'Asia/Dubai'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_business public.businesses;
  v_member public.business_members;
  v_user_id uuid := auth.uid();
  v_name text := btrim(business_name);
  v_currency text := upper(btrim(currency_code));
  v_timezone text := btrim(timezone_name);
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF length(v_name) < 2 OR length(v_name) > 200 THEN
    RAISE EXCEPTION 'Business name must contain between 2 and 200 characters' USING ERRCODE = '23514';
  END IF;

  IF v_currency !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'Currency must be a 3-letter ISO currency code' USING ERRCODE = '23514';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_timezone_names
    WHERE name = v_timezone
  ) THEN
    RAISE EXCEPTION 'Invalid timezone' USING ERRCODE = '22023';
  END IF;

  -- Serialize first-time onboarding for this Auth subject. The membership
  -- constraint is scoped to (business_id, user_id), so concurrent requests
  -- otherwise can both pass the existence check and create separate businesses.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'nabuuma:create_business:' || v_user_id::text,
      0
    )
  );

  -- Preserve the existing one-business onboarding behavior.
  IF EXISTS (
    SELECT 1
    FROM public.business_members
    WHERE user_id = v_user_id
  ) THEN
    SELECT bm.*
    INTO v_member
    FROM public.business_members AS bm
    WHERE bm.user_id = v_user_id
    ORDER BY bm.created_at
    LIMIT 1;

    RETURN jsonb_build_object(
      'business_id', v_member.business_id,
      'role', v_member.role,
      'already_member', true
    );
  END IF;

  INSERT INTO public.businesses (name, currency, timezone)
  VALUES (v_name, v_currency, v_timezone)
  RETURNING * INTO v_business;

  INSERT INTO public.business_members (business_id, user_id, role)
  VALUES (v_business.id, v_user_id, 'owner'::public.member_role)
  RETURNING * INTO v_member;

  INSERT INTO public.subscriptions (business_id, plan_code, status)
  VALUES (v_business.id, 'pilot', 'trialing');

  RETURN jsonb_build_object(
    'business_id', v_business.id,
    'role', v_member.role,
    'already_member', false,
    'business', jsonb_build_object(
      'id', v_business.id,
      'name', v_business.name,
      'currency', v_business.currency,
      'timezone', v_business.timezone
    )
  );
END;
$function$;
ALTER FUNCTION create_business(text,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION create_business(text,text,text) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION create_business(text,text,text) TO "service_role", "authenticated";
CREATE OR REPLACE FUNCTION public.current_user_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ SELECT auth.uid() $function$;
ALTER FUNCTION current_user_id() OWNER TO postgres;
REVOKE ALL ON FUNCTION current_user_id() FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION current_user_id() TO PUBLIC, "anon", "authenticated", "service_role";
CREATE OR REPLACE FUNCTION public.has_role(target_business uuid, allowed member_role[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ SELECT EXISTS (SELECT 1 FROM public.business_members WHERE business_id=target_business AND user_id=auth.uid() AND role=ANY(allowed)) $function$;
ALTER FUNCTION has_role(uuid,member_role[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION has_role(uuid,member_role[]) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION has_role(uuid,member_role[]) TO "service_role", "authenticated", "anon";
CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ SELECT EXISTS (SELECT 1 FROM public.users WHERE id=auth.uid() AND role='admin') $function$;
ALTER FUNCTION is_admin() OWNER TO postgres;
REVOKE ALL ON FUNCTION is_admin() FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION is_admin() TO PUBLIC, "anon", "authenticated", "service_role";
CREATE OR REPLACE FUNCTION public.is_member(target_business uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ SELECT EXISTS (SELECT 1 FROM public.business_members WHERE business_id=target_business AND user_id=auth.uid()) $function$;
ALTER FUNCTION is_member(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION is_member(uuid) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION is_member(uuid) TO "service_role", "authenticated", "anon";
CREATE OR REPLACE FUNCTION public.network_evaluate_financial_finality_gate(p_gate_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$ declare g public.network_financial_finality_gates%rowtype; r record; v_count integer; v_state text:='verified'; v_reason text; v_now timestamptz:=clock_timestamp(); begin select * into g from public.network_financial_finality_gates where gate_id=p_gate_id for update; if not found then raise exception 'finality gate not found'; end if; perform pg_advisory_xact_lock(hashtextextended('v38-gate:'||g.settlement_batch_id::text,0)); for r in select * from public.network_financial_finality_requirements where gate_id=p_gate_id order by evidence_type loop select count(*) into v_count from public.network_oracle_evidence e where e.evidence_type=r.evidence_type and e.verification_state='verified' and e.expires_at>v_now and (e.settlement_batch_id=g.settlement_batch_id or e.route_id=g.route_id); if v_count<r.required_count then v_state:='blocked'; v_reason:=format('missing verified evidence: %s (%s/%s)',r.evidence_type,v_count,r.required_count); exit; end if; end loop; update public.network_financial_finality_gates set state=v_state,evaluated_at=v_now,blocking_reason=case when v_state='blocked' then v_reason else null end where gate_id=p_gate_id; return v_state; end; $function$;
ALTER FUNCTION network_evaluate_financial_finality_gate(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION network_evaluate_financial_finality_gate(uuid) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION network_evaluate_financial_finality_gate(uuid) TO "service_role";
CREATE OR REPLACE FUNCTION public.protect_system_columns()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$ BEGIN NEW.id:=OLD.id; NEW.business_id:=OLD.business_id; NEW.created_at:=OLD.created_at; RETURN NEW; END $function$;
ALTER FUNCTION protect_system_columns() OWNER TO postgres;
REVOKE ALL ON FUNCTION protect_system_columns() FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION protect_system_columns() TO PUBLIC, "anon", "authenticated", "service_role";
-- Harden the tenant-integrity trigger functions. Their trigger attachments
-- were established by the recovered migration history; only their bodies and
-- fixed search paths are refreshed here.
CREATE OR REPLACE FUNCTION public.enforce_same_business()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
    parent_business uuid;
    child_business uuid;
BEGIN
    IF TG_TABLE_NAME = 'recipe_ingredients' THEN
        SELECT business_id INTO parent_business
        FROM public.recipe_versions
        WHERE id = NEW.recipe_version_id;
        SELECT business_id INTO child_business
        FROM public.ingredients
        WHERE id = NEW.ingredient_id;
    ELSIF TG_TABLE_NAME = 'ingredient_prices' THEN
        SELECT business_id INTO parent_business
        FROM public.ingredients
        WHERE id = NEW.ingredient_id;
        child_business := NEW.business_id;
    ELSIF TG_TABLE_NAME = 'recipe_versions' THEN
        SELECT business_id INTO parent_business
        FROM public.products
        WHERE id = NEW.product_id;
        child_business := NEW.business_id;
    ELSIF TG_TABLE_NAME IN ('inventory_movements', 'waste_records') THEN
        SELECT business_id INTO parent_business
        FROM public.ingredients
        WHERE id = NEW.ingredient_id;
        child_business := NEW.business_id;
    ELSIF TG_TABLE_NAME IN (
        'training_assignments', 'assessments', 'certifications'
    ) THEN
        SELECT business_id INTO parent_business
        FROM public.staff_profiles
        WHERE id = NEW.staff_id;
        SELECT business_id INTO child_business
        FROM public.courses
        WHERE id = NEW.course_id;
    ELSIF TG_TABLE_NAME IN ('qc_checks', 'service_events') THEN
        SELECT business_id INTO parent_business
        FROM public.products
        WHERE id = NEW.product_id;
        child_business := NEW.business_id;
    ELSE
        RETURN NEW;
    END IF;

    IF parent_business IS NULL
       OR child_business IS NULL
       OR parent_business <> child_business THEN
        RAISE EXCEPTION 'Cross-business reference rejected';
    END IF;

    RETURN NEW;
END
$function$;
ALTER FUNCTION public.enforce_same_business() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.enforce_same_business()
FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;

CREATE OR REPLACE FUNCTION public.enforce_price_supplier_business()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
    ingredient_business uuid;
    supplier_business uuid;
BEGIN
    SELECT business_id
    INTO ingredient_business
    FROM public.ingredients
    WHERE id = NEW.ingredient_id;

    IF NEW.supplier_id IS NOT NULL THEN
        SELECT business_id
        INTO supplier_business
        FROM public.suppliers
        WHERE id = NEW.supplier_id;
    END IF;

    IF ingredient_business IS NULL
       OR ingredient_business <> NEW.business_id
       OR (
           NEW.supplier_id IS NOT NULL
           AND supplier_business IS DISTINCT FROM NEW.business_id
       ) THEN
        RAISE EXCEPTION 'Cross-business price reference rejected';
    END IF;

    RETURN NEW;
END
$function$;
ALTER FUNCTION public.enforce_price_supplier_business() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.enforce_price_supplier_business()
FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;

CREATE OR REPLACE FUNCTION public.prevent_published_recipe_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
    v_publish_authorized boolean :=
        current_user = 'postgres'
        AND COALESCE(
            pg_catalog.current_setting('nabuuma.publish_recipe', true) = 'on',
            false
        );
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status = 'published' THEN
            RAISE EXCEPTION 'Published recipe versions are immutable';
        END IF;
        RETURN OLD;
    END IF;

    IF OLD.status = 'published' THEN
        IF v_publish_authorized
           AND NEW.status = 'archived'
           AND (pg_catalog.to_jsonb(NEW) - 'status') =
               (pg_catalog.to_jsonb(OLD) - 'status') THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'Published recipe versions are immutable';
    END IF;

    IF NEW.status = 'published' AND NOT v_publish_authorized THEN
        RAISE EXCEPTION 'Use publish_recipe() to publish recipes';
    END IF;

    RETURN NEW;
END
$function$;
ALTER FUNCTION public.prevent_published_recipe_change() OWNER TO postgres;

CREATE OR REPLACE FUNCTION public.publish_recipe(p_recipe uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO pg_catalog, pg_temp
AS $function$
DECLARE
    r public.recipe_versions%ROWTYPE;
    v_product_id uuid;
    v_business_id uuid;
    v_product_business_id uuid;
BEGIN
    SELECT * INTO r
    FROM public.recipe_versions
    WHERE id = p_recipe;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Not permitted';
    END IF;

    v_product_id := r.product_id;
    v_business_id := r.business_id;

    IF NOT public.has_role(
        v_business_id,
        ARRAY['owner','manager','trainer']::public.member_role[]
    ) THEN
        RAISE EXCEPTION 'Not permitted';
    END IF;

    -- Serialize publications for one product and verify the recipe belongs
    -- to that product's business before changing either record.
    SELECT p.business_id
    INTO v_product_business_id
    FROM public.products AS p
    WHERE p.id = v_product_id
    FOR UPDATE;

    IF NOT FOUND OR v_product_business_id IS DISTINCT FROM v_business_id THEN
        RAISE EXCEPTION 'Not permitted';
    END IF;

    SELECT *
    INTO r
    FROM public.recipe_versions
    WHERE id = p_recipe
    FOR UPDATE;

    IF NOT FOUND
       OR r.product_id IS DISTINCT FROM v_product_id
       OR r.business_id IS DISTINCT FROM v_business_id THEN
        RAISE EXCEPTION 'Recipe changed during publication; retry';
    END IF;

    IF NOT public.has_role(
        r.business_id,
        ARRAY['owner','manager','trainer']::public.member_role[]
    ) THEN
        RAISE EXCEPTION 'Not permitted';
    END IF;

    IF r.status = 'published' THEN
        IF EXISTS (
            SELECT 1
            FROM public.recipe_versions AS other_version
            WHERE other_version.product_id = r.product_id
              AND other_version.business_id = r.business_id
              AND other_version.status = 'published'
              AND other_version.id <> r.id
        ) THEN
            RAISE EXCEPTION 'Product has multiple published recipe versions';
        END IF;

        UPDATE public.products
        SET active_recipe_version_id = r.id
        WHERE id = r.product_id
          AND business_id = r.business_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Not permitted';
        END IF;
        RETURN;
    END IF;

    PERFORM pg_catalog.set_config('nabuuma.publish_recipe', 'on', true);

    UPDATE public.recipe_versions
    SET status = 'archived'
    WHERE product_id = r.product_id
      AND business_id = r.business_id
      AND status = 'published'
      AND id <> r.id;

    UPDATE public.recipe_versions
    SET status = 'published',
        published_at = pg_catalog.now()
    WHERE id = r.id
      AND product_id = r.product_id
      AND business_id = r.business_id
      AND status <> 'published';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recipe could not be published; retry';
    END IF;

    UPDATE public.products
    SET active_recipe_version_id = r.id
    WHERE id = r.product_id
      AND business_id = r.business_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Not permitted';
    END IF;

    PERFORM pg_catalog.set_config('nabuuma.publish_recipe', 'off', true);
END
$function$;
ALTER FUNCTION publish_recipe(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION publish_recipe(uuid) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION publish_recipe(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.v20_hash_inventory_entry(p_transaction_id uuid, p_business_id uuid, p_ingredient_id uuid, p_location_id uuid, p_batch_id uuid, p_unit text, p_quantity numeric, p_unit_cost_minor bigint, p_previous_hash text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ SELECT encode(extensions.digest(pg_catalog.concat_ws('|',coalesce(p_transaction_id::text,''),coalesce(p_business_id::text,''),coalesce(p_ingredient_id::text,''),coalesce(p_location_id::text,''),coalesce(p_batch_id::text,''),p_unit,p_quantity::text,p_unit_cost_minor::text,coalesce(p_previous_hash,'')),'sha256'),'hex') $function$;
ALTER FUNCTION v20_hash_inventory_entry(uuid,uuid,uuid,uuid,uuid,text,numeric,bigint,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION v20_hash_inventory_entry(uuid,uuid,uuid,uuid,uuid,text,numeric,bigint,text) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION v20_hash_inventory_entry(uuid,uuid,uuid,uuid,uuid,text,numeric,bigint,text) TO "service_role", "authenticated";
CREATE OR REPLACE FUNCTION public.v20_inventory_immutable_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$ BEGIN RAISE EXCEPTION 'Inventory ledger entries are immutable'; END $function$;
ALTER FUNCTION v20_inventory_immutable_guard() OWNER TO postgres;
REVOKE ALL ON FUNCTION v20_inventory_immutable_guard() FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION v20_inventory_immutable_guard() TO "service_role";
CREATE OR REPLACE FUNCTION public.v21_hash_execution_receipt(p_business_id uuid, p_transaction_id uuid, p_receipt_type text, p_evidence_hash text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ SELECT encode(extensions.digest(pg_catalog.concat_ws('|',p_business_id::text,p_transaction_id::text,p_receipt_type,p_evidence_hash),'sha256'),'hex') $function$;
ALTER FUNCTION v21_hash_execution_receipt(uuid,uuid,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION v21_hash_execution_receipt(uuid,uuid,text,text) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION v21_hash_execution_receipt(uuid,uuid,text,text) TO "service_role", "authenticated";
CREATE OR REPLACE FUNCTION public.v22_finalize_cross_border_pod(p_manifest_id uuid, p_dispatch_id uuid, p_delivered_at timestamp with time zone, p_evidence_hash text)
 RETURNS gcc_cross_border_pod
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_manifest public.gcc_cross_border_manifests;
  v_dispatch public.network_order_dispatches;
  v_existing public.gcc_cross_border_pod;
  v_result public.gcc_cross_border_pod;
  v_uid uuid := (SELECT auth.uid());
  v_hash text := lower(btrim(p_evidence_hash));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required.' USING ERRCODE = '42501';
  END IF;

  IF p_manifest_id IS NULL OR p_dispatch_id IS NULL THEN
    RAISE EXCEPTION 'Manifest and dispatch are required.' USING ERRCODE = '23514';
  END IF;

  IF p_delivered_at IS NULL THEN
    RAISE EXCEPTION 'Delivered timestamp is required.' USING ERRCODE = '23514';
  END IF;

  IF v_hash IS NULL OR v_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Evidence hash must be a 64-character hexadecimal SHA-256 value.' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO v_manifest
  FROM public.gcc_cross_border_manifests
  WHERE manifest_id = p_manifest_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manifest not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    public.is_member(v_manifest.business_id)
    OR public.is_member(v_manifest.seller_business_id)
    OR public.is_member(v_manifest.buyer_business_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized for manifest.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_dispatch
  FROM public.network_order_dispatches
  WHERE id = p_dispatch_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Dispatch not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    public.is_member(v_dispatch.buyer_business_id)
    OR public.is_member(v_dispatch.seller_business_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized for dispatch.' USING ERRCODE = '42501';
  END IF;

  IF v_dispatch.buyer_business_id <> v_manifest.buyer_business_id
     OR v_dispatch.seller_business_id <> v_manifest.seller_business_id THEN
    RAISE EXCEPTION 'Structural invariant failure: dispatch participants do not match manifest.' USING ERRCODE = '23514';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.gcc_cross_border_manifest_lines ml
    WHERE ml.manifest_id = p_manifest_id
      AND ml.source_dispatch_id = p_dispatch_id
  ) THEN
    RAISE EXCEPTION 'Structural invariant failure: dispatch is not linked to manifest lines.' USING ERRCODE = '23514';
  END IF;

  -- A POD can only finalize a delivered dispatch.
  IF v_dispatch.status <> 'delivered' THEN
    RAISE EXCEPTION 'Dispatch must be delivered before POD finalization.' USING ERRCODE = '23514';
  END IF;

  -- Permit an exact retry; reject conflicting duplicate finalization.
  SELECT * INTO v_existing
  FROM public.gcc_cross_border_pod
  WHERE manifest_id = p_manifest_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing.status = 'submitted'
       AND v_existing.delivered_at = p_delivered_at
       AND lower(coalesce(v_existing.evidence_hash, '')) = v_hash THEN
      RETURN v_existing;
    END IF;
    RAISE EXCEPTION 'A conflicting POD already exists for this manifest.' USING ERRCODE = '23505';
  END IF;

  IF v_manifest.status NOT IN ('dispatched', 'delivered') THEN
    RAISE EXCEPTION 'Manifest is not in a POD-finalizable state.' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.gcc_cross_border_pod (
    manifest_id,
    delivered_at,
    received_by,
    evidence_hash,
    status
  ) VALUES (
    p_manifest_id,
    p_delivered_at,
    v_uid,
    v_hash,
    'submitted'
  )
  RETURNING * INTO v_result;

  UPDATE public.gcc_cross_border_manifests
  SET status = 'delivered', updated_at = clock_timestamp()
  WHERE manifest_id = p_manifest_id
    AND status IN ('dispatched', 'delivered');

  RETURN v_result;
END;
$function$;
ALTER FUNCTION v22_finalize_cross_border_pod(uuid,uuid,timestamp with time zone,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION v22_finalize_cross_border_pod(uuid,uuid,timestamp with time zone,text) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION v22_finalize_cross_border_pod(uuid,uuid,timestamp with time zone,text) TO "service_role", "authenticated";
CREATE OR REPLACE FUNCTION public.v22_upsert_shipment_milestone(p_shipment_id uuid, p_milestone_code text, p_occurred_at timestamp with time zone DEFAULT now(), p_source text DEFAULT 'user'::text, p_notes text DEFAULT NULL::text)
 RETURNS v22_logistics_milestones
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_shipment public.v22_logistics_shipments;
  v_id uuid;
  v_result public.v22_logistics_milestones;
BEGIN
  IF (select auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'Authentication required.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_shipment
  FROM public.v22_logistics_shipments
  WHERE id = p_shipment_id
  FOR UPDATE;

  IF v_shipment.id IS NULL THEN
    RAISE EXCEPTION 'Shipment not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (select public.has_role(v_shipment.business_id, ARRAY['owner','manager','staff']::public.member_role[])) THEN
    RAISE EXCEPTION 'Not authorized for shipment business.' USING ERRCODE = '42501';
  END IF;

  v_id := public.record_v22_logistics_milestone(
    p_shipment_id,
    p_milestone_code,
    p_occurred_at,
    p_source,
    p_notes
  );

  SELECT * INTO v_result
  FROM public.v22_logistics_milestones
  WHERE id = v_id;

  RETURN v_result;
END;
$function$;
ALTER FUNCTION v22_upsert_shipment_milestone(uuid,text,timestamp with time zone,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION v22_upsert_shipment_milestone(uuid,text,timestamp with time zone,text,text) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION v22_upsert_shipment_milestone(uuid,text,timestamp with time zone,text,text) TO "service_role", "authenticated";
CREATE OR REPLACE FUNCTION public.v23_hash_recovery_action(p_business_id uuid, p_source_type text, p_source_id uuid, p_action_type text, p_reason_code text, p_evidence_hash text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ SELECT encode(extensions.digest(pg_catalog.concat_ws('|',p_business_id::text,p_source_type,p_source_id::text,p_action_type,p_reason_code,lower(p_evidence_hash)),'sha256'),'hex') $function$;
ALTER FUNCTION v23_hash_recovery_action(uuid,text,uuid,text,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION v23_hash_recovery_action(uuid,text,uuid,text,text,text) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION v23_hash_recovery_action(uuid,text,uuid,text,text,text) TO "service_role", "authenticated";
CREATE OR REPLACE FUNCTION public.v24_hash_recovery_approval(p_business_id uuid, p_action_id uuid, p_approver_user_id uuid, p_decision text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ SELECT encode(extensions.digest(pg_catalog.concat_ws('|',p_business_id::text,p_action_id::text,p_approver_user_id::text,p_decision),'sha256'),'hex') $function$;
ALTER FUNCTION v24_hash_recovery_approval(uuid,uuid,uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION v24_hash_recovery_approval(uuid,uuid,uuid,text) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION v24_hash_recovery_approval(uuid,uuid,uuid,text) TO "service_role", "authenticated";
CREATE OR REPLACE FUNCTION public.v25_hash_automation_event(p_business_id uuid, p_event_type text, p_source_type text, p_source_id uuid, p_payload jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ SELECT encode(extensions.digest(pg_catalog.concat_ws('|',p_business_id::text,p_event_type,p_source_type,p_source_id::text,p_payload::text),'sha256'),'hex') $function$;
ALTER FUNCTION v25_hash_automation_event(uuid,text,text,uuid,jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION v25_hash_automation_event(uuid,text,text,uuid,jsonb) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION v25_hash_automation_event(uuid,text,text,uuid,jsonb) TO "service_role", "authenticated";
CREATE OR REPLACE FUNCTION public.v32_financial_account_id(p_business_id uuid, p_code text, p_currency text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_id uuid;
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN RAISE EXCEPTION 'trusted executor required'; END IF;
  SELECT id INTO v_id FROM public.financial_accounts WHERE business_id=p_business_id AND account_code=p_code AND currency=p_currency FOR UPDATE;
  IF v_id IS NULL THEN
    INSERT INTO public.financial_accounts(business_id,account_code,account_name,account_type,currency)
    VALUES
      (p_business_id,'CASH','Cash','Asset',p_currency),
      (p_business_id,'ESCROW_ASSET','Settlement Escrow','Asset',p_currency),
      (p_business_id,'AP','Accounts Payable','Liability',p_currency),
      (p_business_id,'AR','Accounts Receivable','Asset',p_currency),
      (p_business_id,'REVENUE','Network Revenue','Revenue',p_currency),
      (p_business_id,'EXPENSE','Network Expense','Expense',p_currency),
      (p_business_id,'EQUITY','Equity','Equity',p_currency)
    ON CONFLICT (business_id,account_code,currency) DO NOTHING;
    SELECT id INTO v_id FROM public.financial_accounts WHERE business_id=p_business_id AND account_code=p_code AND currency=p_currency FOR UPDATE;
  END IF;
  IF v_id IS NULL THEN RAISE EXCEPTION 'financial account creation failed'; END IF;
  RETURN v_id;
END;
$function$;
ALTER FUNCTION v32_financial_account_id(uuid,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION v32_financial_account_id(uuid,text,text) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION v32_financial_account_id(uuid,text,text) TO "service_role";
CREATE OR REPLACE FUNCTION public.v32_three_way_match(p_po_line_id uuid, p_dispatch_line_id uuid, p_delivery_proof_id uuid, p_tax_rate_bps integer DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  po record;
  dl record;
  rc record;
  so record;
  v_dispatch record;
  v_existing uuid;
  v_clear numeric;
  v_po_invoiced numeric;
  v_dispatch_invoiced numeric;
  v_sales_order_invoiced numeric;
  v_receipt_invoiced numeric;
  v_po_remaining numeric;
  v_dispatch_remaining numeric;
  v_sales_order_remaining numeric;
  v_receipt_remaining numeric;
  v_sub_numeric numeric;
  v_tax_numeric numeric;
  v_sub bigint;
  v_tax bigint;
  v_total bigint;
  v_invoice uuid;
  v_invoice_no text;
  v_currency text;
BEGIN
  IF NOT public.v32_is_trusted_executor() THEN
    RAISE EXCEPTION 'trusted executor required';
  END IF;
  IF p_tax_rate_bps IS NULL OR p_tax_rate_bps < 0 OR p_tax_rate_bps > 10000 THEN
    RAISE EXCEPTION 'invalid tax rate';
  END IF;

  /*
   * The lock key covers the complete evidence tuple.  The source rows are
   * then explicitly locked before outstanding quantities are calculated.
   * PostgreSQL row locks block concurrent writers/lockers until transaction
   * end, which is required for a conservative three-way match.
   */
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'nabuuma:v32:match:' ||
      coalesce(p_po_line_id::text,'') || ':' ||
      coalesce(p_dispatch_line_id::text,'') || ':' ||
      coalesce(p_delivery_proof_id::text,''),
      3202
    )
  );

  SELECT i.id
  INTO v_existing
  FROM public.network_invoices i
  JOIN public.network_invoice_lines l ON l.invoice_id=i.id
  WHERE l.purchase_order_line_id=p_po_line_id
    AND l.dispatch_line_id=p_dispatch_line_id
    AND l.delivery_proof_id=p_delivery_proof_id
  LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO po
  FROM public.purchase_order_lines
  WHERE id=p_po_line_id
  FOR UPDATE;

  SELECT disp_line.*, disp.sales_order_id, disp.status AS dispatch_status,
         disp.buyer_business_id AS dispatch_buyer,
         disp.seller_business_id AS dispatch_seller
  INTO dl
  FROM public.network_order_dispatch_lines disp_line
  JOIN public.network_order_dispatches disp ON disp.id=disp_line.dispatch_id
  WHERE disp_line.id=p_dispatch_line_id
  FOR UPDATE;

  SELECT * INTO rc
  FROM public.network_dispatched_receipts
  WHERE id=p_delivery_proof_id
  FOR UPDATE;

  IF po.id IS NULL OR dl.id IS NULL OR rc.id IS NULL THEN
    RAISE EXCEPTION 'three-way evidence row missing';
  END IF;

  SELECT * INTO so
  FROM public.network_sales_order_lines
  WHERE id=dl.sales_order_line_id
  FOR UPDATE;

  SELECT * INTO v_dispatch
  FROM public.network_order_dispatches
  WHERE id=dl.dispatch_id
  FOR UPDATE;

  IF so.id IS NULL OR v_dispatch.id IS NULL THEN
    RAISE EXCEPTION 'sales order/dispatch relationship missing';
  END IF;
  IF dl.dispatch_id <> rc.dispatch_id THEN
    RAISE EXCEPTION 'delivery proof does not belong to dispatch';
  END IF;
  IF dl.buyer_business_id <> v_dispatch.buyer_business_id
     OR dl.seller_business_id <> v_dispatch.seller_business_id
     OR so.buyer_business_id <> v_dispatch.buyer_business_id
     OR so.seller_business_id <> v_dispatch.seller_business_id
     OR rc.buyer_business_id <> v_dispatch.buyer_business_id
     OR rc.seller_business_id <> v_dispatch.seller_business_id THEN
    RAISE EXCEPTION 'tenant party mismatch';
  END IF;
  IF so.ingredient_id IS DISTINCT FROM po.ingredient_id THEN
    RAISE EXCEPTION 'ingredient mismatch between PO and network order';
  END IF;
  IF lower(trim(po.unit)) <> lower(trim(dl.unit))
     OR lower(trim(dl.unit)) <> lower(trim(rc.unit))
     OR lower(trim(rc.unit)) <> lower(trim(so.unit)) THEN
    RAISE EXCEPTION 'exact unit mismatch';
  END IF;
  IF v_dispatch.status <> 'delivered' THEN
    RAISE EXCEPTION 'dispatch must be delivered before invoice compilation';
  END IF;
  IF rc.receipt_status <> 'committed' THEN
    RAISE EXCEPTION 'delivery proof is not committed';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.network_dispatches_disputes x
    WHERE x.dispatch_id=v_dispatch.id
      AND x.status IN ('open','under_review')
  ) THEN
    RAISE EXCEPTION 'dispatch has unresolved dispute';
  END IF;

  /*
   * Outstanding quantity is calculated independently for every evidence
   * node.  The prior implementation used greatest(received, invoiced) for
   * the PO side, which could overstate billable quantity when operational
   * receiving had already recorded more than the invoiced amount.
   */
  SELECT coalesce(sum(l.quantity),0) INTO v_po_invoiced
  FROM public.network_invoice_lines l
  WHERE l.purchase_order_line_id=po.id;

  SELECT coalesce(sum(l.quantity),0) INTO v_dispatch_invoiced
  FROM public.network_invoice_lines l
  WHERE l.dispatch_line_id=dl.id;

  SELECT coalesce(sum(l.quantity),0) INTO v_sales_order_invoiced
  FROM public.network_invoice_lines l
  WHERE l.invoice_id IS NOT NULL
    AND l.dispatch_line_id IN (
      SELECT x.id
      FROM public.network_order_dispatch_lines x
      WHERE x.sales_order_line_id=so.id
    );

  SELECT coalesce(sum(l.quantity),0) INTO v_receipt_invoiced
  FROM public.network_invoice_lines l
  WHERE l.delivery_proof_id=rc.id;

  v_po_remaining := po.ordered_quantity - greatest(v_po_invoiced,0);
  v_dispatch_remaining := dl.quantity - greatest(v_dispatch_invoiced,0);
  v_sales_order_remaining := so.quantity - greatest(v_sales_order_invoiced,0);
  v_receipt_remaining := rc.received_quantity - greatest(v_receipt_invoiced,0);

  v_clear := least(
    v_po_remaining,
    v_dispatch_remaining,
    v_sales_order_remaining,
    v_receipt_remaining
  );

  IF v_po_remaining < 0 OR v_dispatch_remaining < 0
     OR v_sales_order_remaining < 0 OR v_receipt_remaining < 0 THEN
    RAISE EXCEPTION 'existing invoice quantity exceeds source evidence quantity';
  END IF;
  IF v_clear <= 0 THEN
    RAISE EXCEPTION 'no clear quantity remains';
  END IF;

  v_sub_numeric := v_clear * so.unit_price_minor::numeric;
  IF v_sub_numeric <> trunc(v_sub_numeric) THEN
    RAISE EXCEPTION 'fractional minor-unit subtotal is not permitted';
  END IF;
  v_sub := v_sub_numeric::bigint;

  v_tax_numeric := round(v_sub_numeric * p_tax_rate_bps::numeric / 10000,0);
  IF v_tax_numeric <> trunc(v_tax_numeric) THEN
    RAISE EXCEPTION 'tax rounding did not produce an integer minor unit';
  END IF;
  v_tax := v_tax_numeric::bigint;
  v_total := v_sub + v_tax;

  v_currency := (SELECT currency FROM public.network_sales_orders WHERE id=so.sales_order_id);
  IF v_currency IS NULL OR length(v_currency) <> 3 THEN
    RAISE EXCEPTION 'invalid sales-order currency';
  END IF;

  v_invoice := gen_random_uuid();
  v_invoice_no := 'NAB-V32-' || upper(replace(v_invoice::text,'-',''));

  PERFORM set_config('nabuuma.v32_building_invoice','1',true);
  INSERT INTO public.network_invoices(
    id,invoice_number,buyer_business_id,seller_business_id,currency,
    subtotal_minor,tax_minor,total_minor
  )
  VALUES(
    v_invoice,v_invoice_no,v_dispatch.buyer_business_id,v_dispatch.seller_business_id,v_currency,
    v_sub,v_tax,v_total
  );

  INSERT INTO public.network_invoice_lines(
    invoice_id,purchase_order_line_id,dispatch_line_id,delivery_proof_id,
    ingredient_id,quantity,unit,unit_price_minor,subtotal_minor,tax_rate_bps,
    tax_minor,total_minor
  )
  VALUES(
    v_invoice,po.id,dl.id,rc.id,po.ingredient_id,v_clear,po.unit,
    so.unit_price_minor,v_sub,p_tax_rate_bps,v_tax,v_total
  );

  UPDATE public.network_invoices
  SET immutable_block_hash=public.v32_invoice_hash(v_invoice)
  WHERE id=v_invoice;

  PERFORM set_config('nabuuma.v32_building_invoice','0',true);
  RETURN v_invoice;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('nabuuma.v32_building_invoice','0',true);
  RAISE;
END;
$function$;
ALTER FUNCTION v32_three_way_match(uuid,uuid,uuid,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION v32_three_way_match(uuid,uuid,uuid,integer) FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION v32_three_way_match(uuid,uuid,uuid,integer) TO "service_role";

-- Preserve the production no-TRUNCATE boundary on the immutable forensic log.
REVOKE TRUNCATE ON TABLE public.network_ledger_forensic_events FROM service_role;

-- Two pre-existing RPCs had an authenticated EXECUTE grant in the replay,
-- but production exposes them only to service_role. Restore that boundary.
REVOKE ALL ON FUNCTION public.append_financial_forensic_entry(uuid,uuid,jsonb)
FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.append_financial_forensic_entry(uuid,uuid,jsonb) TO service_role;

REVOKE ALL ON FUNCTION public.calculate_gcc_localized_valuation(uuid,text)
FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.calculate_gcc_localized_valuation(uuid,text) TO service_role;

-- ---------------------------------------------------------------------------
-- Catalog verification
-- ---------------------------------------------------------------------------

DO $verify$
DECLARE
    v_network_fn oid := pg_catalog.to_regprocedure('public.network_execute_settlement_route(uuid)');
    v_todo oid := pg_catalog.to_regclass('public.todos');
    v_org oid := pg_catalog.to_regclass('nabuuma.organisations');
    v_membership oid := pg_catalog.to_regclass('nabuuma.organisation_memberships');
    v_hook oid := pg_catalog.to_regprocedure('nabuuma.custom_access_token_hook(jsonb)');
    v_publish oid := pg_catalog.to_regprocedure('public.publish_recipe(uuid)');
    v_recipe_costs oid := pg_catalog.to_regclass('public.recipe_costs');
    v_trigger_count integer;
BEGIN
    IF v_network_fn IS NULL OR NOT pg_catalog.has_function_privilege('service_role', v_network_fn, 'EXECUTE') THEN
        RAISE EXCEPTION 'network_execute_settlement_route must be executable by service_role';
    END IF;
    IF pg_catalog.has_function_privilege('anon', v_network_fn, 'EXECUTE')
       OR pg_catalog.has_function_privilege('authenticated', v_network_fn, 'EXECUTE') THEN
        RAISE EXCEPTION 'network_execute_settlement_route is exposed to a client role';
    END IF;

    SELECT count(*) INTO v_trigger_count
      FROM pg_catalog.pg_trigger t
      JOIN pg_catalog.pg_proc p ON p.oid=t.tgfoid
     WHERE NOT t.tgisinternal
       AND p.proname='audit_purchase_order_row_change_v1';
    IF v_trigger_count <> 4 THEN
        RAISE EXCEPTION 'Expected four purchase-order/goods-receipt audit triggers; found %',v_trigger_count;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid='public.audit_purchase_order_status_change()'::regprocedure) THEN
        RAISE EXCEPTION 'Legacy audit_purchase_order_status_change function missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_event_trigger
         WHERE evtname='ensure_rls'
           AND evtevent='ddl_command_end'
           AND evtenabled='O'
           AND evttags @> ARRAY['CREATE TABLE','CREATE TABLE AS','SELECT INTO']
    ) THEN
        RAISE EXCEPTION 'ensure_rls event trigger missing or disabled';
    END IF;

    IF v_todo IS NULL
       OR NOT (SELECT relrowsecurity AND NOT relforcerowsecurity FROM pg_catalog.pg_class WHERE oid=v_todo) THEN
        RAISE EXCEPTION 'public.todos RLS boundary is not restored';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_policies
         WHERE schemaname='public' AND tablename='todos'
           AND policyname='Users can only access their own todos'
           AND 'authenticated'=ANY(roles)
    ) THEN
        RAISE EXCEPTION 'public.todos owner policy missing';
    END IF;
    IF pg_catalog.has_table_privilege('anon',v_todo,'SELECT')
       OR NOT pg_catalog.has_table_privilege('authenticated',v_todo,'SELECT')
       OR NOT pg_catalog.has_table_privilege('authenticated',v_todo,'INSERT')
       OR NOT pg_catalog.has_table_privilege('authenticated',v_todo,'UPDATE')
       OR NOT pg_catalog.has_table_privilege('authenticated',v_todo,'DELETE')
       OR NOT pg_catalog.has_table_privilege('service_role',v_todo,'MAINTAIN') THEN
        RAISE EXCEPTION 'public.todos ACL does not match production';
    END IF;

    IF v_org IS NULL OR v_membership IS NULL THEN
        RAISE EXCEPTION 'Private nabuuma organisation tables missing';
    END IF;

    IF v_hook IS NULL
       OR NOT pg_catalog.has_function_privilege('supabase_auth_admin',v_hook,'EXECUTE')
       OR pg_catalog.has_function_privilege('anon',v_hook,'EXECUTE')
       OR pg_catalog.has_function_privilege('authenticated',v_hook,'EXECUTE')
       OR pg_catalog.has_function_privilege('service_role',v_hook,'EXECUTE') THEN
        RAISE EXCEPTION 'Custom access-token hook ACL does not match production';
    END IF;
    IF v_publish IS NULL
       OR NOT pg_catalog.has_function_privilege('service_role',v_publish,'EXECUTE')
       OR pg_catalog.has_function_privilege('anon',v_publish,'EXECUTE')
       OR pg_catalog.has_function_privilege('authenticated',v_publish,'EXECUTE') THEN
        RAISE EXCEPTION 'publish_recipe ACL does not match production';
    END IF;
    IF v_recipe_costs IS NULL
       OR NOT (SELECT reloptions @> ARRAY['security_invoker=true'] FROM pg_catalog.pg_class WHERE oid=v_recipe_costs)
       OR NOT pg_catalog.has_table_privilege('anon',v_recipe_costs,'SELECT')
       OR NOT pg_catalog.has_table_privilege('authenticated',v_recipe_costs,'SELECT')
       OR NOT pg_catalog.has_table_privilege('service_role',v_recipe_costs,'SELECT') THEN
        RAISE EXCEPTION 'recipe_costs view definition or grants are incomplete';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname='financial_ledger_transaction_balance_ct' AND tgconstraint<>0 AND tgdeferrable AND tginitdeferred)
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname='network_ledger_forensic_events_no_truncate' AND (tgtype & 32)=32) THEN
        RAISE EXCEPTION 'Recovered financial/forensic trigger definitions are incomplete';
    END IF;
    IF pg_catalog.has_table_privilege('service_role','public.network_ledger_forensic_events','TRUNCATE') THEN
        RAISE EXCEPTION 'service_role must not have TRUNCATE on the immutable forensic log';
    END IF;
    IF NOT (SELECT relrowsecurity AND NOT relforcerowsecurity FROM pg_catalog.pg_class WHERE oid=v_org)
       OR NOT (SELECT relrowsecurity AND NOT relforcerowsecurity FROM pg_catalog.pg_class WHERE oid=v_membership) THEN
        RAISE EXCEPTION 'Private nabuuma tables must have enabled, non-forced RLS';
    END IF;
    IF pg_catalog.has_schema_privilege('anon','nabuuma','USAGE')
       OR pg_catalog.has_schema_privilege('authenticated','nabuuma','USAGE')
       OR pg_catalog.has_schema_privilege('service_role','nabuuma','USAGE') THEN
        RAISE EXCEPTION 'Private nabuuma schema must remain owner-only';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_policies WHERE schemaname='nabuuma') THEN
        RAISE EXCEPTION 'Unexpected policies found in private nabuuma schema';
    END IF;
END
$verify$;

COMMIT;
