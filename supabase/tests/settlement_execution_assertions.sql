\set ON_ERROR_STOP on

-- Runtime contract tests for network settlement execution.
-- Fixtures are transaction-scoped and are rolled back at the end.
BEGIN;

INSERT INTO public.businesses (id, name, currency, timezone) VALUES
  ('a7bce5e8-9bca-4dd9-bdb8-000000000001', 'Settlement test buyer', 'AED', 'Asia/Dubai'),
  ('a7bce5e8-9bca-4dd9-bdb8-000000000002', 'Settlement test seller', 'AED', 'Asia/Dubai');

INSERT INTO public.settlement_batches (
    id, batch_number, buyer_business_id, seller_business_id,
    currency, state, total_minor
) VALUES
  ('a7bce5e8-9bca-4dd9-bdb8-000000000011', 'TEST-SETTLE-INSUFFICIENT',
   'a7bce5e8-9bca-4dd9-bdb8-000000000001', 'a7bce5e8-9bca-4dd9-bdb8-000000000002',
   'AED', 'compiled', 100),
  ('a7bce5e8-9bca-4dd9-bdb8-000000000012', 'TEST-SETTLE-MISMATCH',
   'a7bce5e8-9bca-4dd9-bdb8-000000000001', 'a7bce5e8-9bca-4dd9-bdb8-000000000002',
   'AED', 'compiled', 100),
  ('a7bce5e8-9bca-4dd9-bdb8-000000000013', 'TEST-SETTLE-NO-GATE',
   'a7bce5e8-9bca-4dd9-bdb8-000000000001', 'a7bce5e8-9bca-4dd9-bdb8-000000000002',
   'AED', 'compiled', 100),
  ('a7bce5e8-9bca-4dd9-bdb8-000000000014', 'TEST-SETTLE-RESERVATION',
   'a7bce5e8-9bca-4dd9-bdb8-000000000001', 'a7bce5e8-9bca-4dd9-bdb8-000000000002',
   'AED', 'compiled', 100),
  ('a7bce5e8-9bca-4dd9-bdb8-000000000015', 'TEST-SETTLE-IDEMPOTENT',
   'a7bce5e8-9bca-4dd9-bdb8-000000000001', 'a7bce5e8-9bca-4dd9-bdb8-000000000002',
   'AED', 'reconciled', 100);

INSERT INTO public.network_settlement_routes (
    route_id, settlement_batch_id, buyer_business_id, seller_business_id,
    currency, principal_minor, state
) VALUES
  ('a7bce5e8-9bca-4dd9-bdb8-000000000021', 'a7bce5e8-9bca-4dd9-bdb8-000000000012',
   'a7bce5e8-9bca-4dd9-bdb8-000000000001', 'a7bce5e8-9bca-4dd9-bdb8-000000000002',
   'AED', 90, 'authorized'),
  ('a7bce5e8-9bca-4dd9-bdb8-000000000022', 'a7bce5e8-9bca-4dd9-bdb8-000000000013',
   'a7bce5e8-9bca-4dd9-bdb8-000000000001', 'a7bce5e8-9bca-4dd9-bdb8-000000000002',
   'AED', 100, 'authorized'),
  ('a7bce5e8-9bca-4dd9-bdb8-000000000023', 'a7bce5e8-9bca-4dd9-bdb8-000000000014',
   'a7bce5e8-9bca-4dd9-bdb8-000000000001', 'a7bce5e8-9bca-4dd9-bdb8-000000000002',
   'AED', 100, 'authorized'),
  ('a7bce5e8-9bca-4dd9-bdb8-000000000024', 'a7bce5e8-9bca-4dd9-bdb8-000000000015',
   'a7bce5e8-9bca-4dd9-bdb8-000000000001', 'a7bce5e8-9bca-4dd9-bdb8-000000000002',
   'AED', 100, 'completed');

INSERT INTO public.network_financial_finality_gates (
    gate_id, settlement_batch_id, route_id, state, blocking_reason, gate_hash
) VALUES
  ('a7bce5e8-9bca-4dd9-bdb8-000000000031', 'a7bce5e8-9bca-4dd9-bdb8-000000000014',
   'a7bce5e8-9bca-4dd9-bdb8-000000000023', 'pending', 'not evaluated', repeat('a', 64)),
  ('a7bce5e8-9bca-4dd9-bdb8-000000000032', 'a7bce5e8-9bca-4dd9-bdb8-000000000015',
   'a7bce5e8-9bca-4dd9-bdb8-000000000024', 'consumed', NULL, repeat('b', 64));

DO $settlement_assertions$
DECLARE
    v_error text;
    v_route_id uuid;
BEGIN
    -- Insufficient liquidity must leave no partially compiled route behind.
    BEGIN
        PERFORM public.network_compile_settlement_route(
            'a7bce5e8-9bca-4dd9-bdb8-000000000011'
        );
        RAISE EXCEPTION 'route compiler accepted a batch with no liquidity';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error NOT LIKE '%insufficient liquidity capacity%' THEN
            RAISE EXCEPTION 'unexpected insufficient-liquidity result: %', v_error;
        END IF;
    END;

    IF EXISTS (
        SELECT 1 FROM public.network_settlement_routes
        WHERE settlement_batch_id = 'a7bce5e8-9bca-4dd9-bdb8-000000000011'
    ) THEN
        RAISE EXCEPTION 'failed route compilation left a route row behind';
    END IF;

    -- A route cannot redirect a different principal/tenant/currency batch.
    BEGIN
        PERFORM public.network_execute_settlement_route(
            'a7bce5e8-9bca-4dd9-bdb8-000000000021'
        );
        RAISE EXCEPTION 'executor accepted a route/batch principal mismatch';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error NOT LIKE '%does not match settlement batch%' THEN
            RAISE EXCEPTION 'unexpected route/batch mismatch result: %', v_error;
        END IF;
    END;

    -- An authorized route without its exact batch+route finality gate is blocked.
    BEGIN
        PERFORM public.network_execute_settlement_route(
            'a7bce5e8-9bca-4dd9-bdb8-000000000022'
        );
        RAISE EXCEPTION 'executor accepted a route without a finality gate';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error NOT LIKE '%finality gate not found%' THEN
            RAISE EXCEPTION 'unexpected missing-gate result: %', v_error;
        END IF;
    END;

    -- The gate may evaluate, but execution must reject missing reservations.
    -- The failed statement must roll back the gate evaluation as well.
    BEGIN
        PERFORM public.network_execute_settlement_route(
            'a7bce5e8-9bca-4dd9-bdb8-000000000023'
        );
        RAISE EXCEPTION 'executor accepted an unreserved settlement principal';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error NOT LIKE '%liquidity reservation mismatch%' THEN
            RAISE EXCEPTION 'unexpected reservation-integrity result: %', v_error;
        END IF;
    END;

    IF (SELECT state FROM public.network_financial_finality_gates
        WHERE gate_id = 'a7bce5e8-9bca-4dd9-bdb8-000000000031') <> 'pending' THEN
        RAISE EXCEPTION 'failed execution did not roll back finality-gate evaluation';
    END IF;

    IF (SELECT state FROM public.network_settlement_routes
        WHERE route_id = 'a7bce5e8-9bca-4dd9-bdb8-000000000023') <> 'authorized' THEN
        RAISE EXCEPTION 'failed execution changed route state';
    END IF;

    -- A fully completed route with reconciled batch, consumed gate and no
    -- outstanding reservations must return the same route on retry.
    v_route_id := public.network_execute_settlement_route(
        'a7bce5e8-9bca-4dd9-bdb8-000000000024'
    );
    IF v_route_id <> 'a7bce5e8-9bca-4dd9-bdb8-000000000024'::uuid THEN
        RAISE EXCEPTION 'idempotent retry returned a different route id';
    END IF;
END
$settlement_assertions$;

ROLLBACK;

SELECT 'PASS: settlement execution boundary and rollback contracts verified' AS result;
