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

-- A complete procurement-to-settlement path for the positive execution test.
INSERT INTO public.suppliers (id, business_id, name)
VALUES ('a7bce5e8-9bca-4dd9-bdb8-000000000041',
        'a7bce5e8-9bca-4dd9-bdb8-000000000001', 'Settlement test supplier');

INSERT INTO public.ingredients (id, business_id, name, base_unit)
VALUES ('a7bce5e8-9bca-4dd9-bdb8-000000000042',
        'a7bce5e8-9bca-4dd9-bdb8-000000000002', 'Settlement test ingredient', 'each');

INSERT INTO public.purchase_orders (
    id, business_id, supplier_id, status, order_number
) VALUES (
    'a7bce5e8-9bca-4dd9-bdb8-000000000043',
    'a7bce5e8-9bca-4dd9-bdb8-000000000001',
    'a7bce5e8-9bca-4dd9-bdb8-000000000041', 'received', 'TEST-PO-SETTLEMENT'
);

INSERT INTO public.purchase_order_lines (
    id, business_id, purchase_order_id, ingredient_id,
    unit, ordered_quantity, received_quantity, unit_price
) VALUES (
    'a7bce5e8-9bca-4dd9-bdb8-000000000044',
    'a7bce5e8-9bca-4dd9-bdb8-000000000001',
    'a7bce5e8-9bca-4dd9-bdb8-000000000043',
    'a7bce5e8-9bca-4dd9-bdb8-000000000042', 'each', 1, 0, 10
);

INSERT INTO public.network_sales_orders (
    id, buyer_business_id, seller_business_id, order_number,
    currency, status, total_minor
) VALUES (
    'a7bce5e8-9bca-4dd9-bdb8-000000000045',
    'a7bce5e8-9bca-4dd9-bdb8-000000000001',
    'a7bce5e8-9bca-4dd9-bdb8-000000000002',
    'TEST-SO-SETTLEMENT', 'AED', 'delivered', 1000
);

INSERT INTO public.network_sales_order_lines (
    id, sales_order_id, buyer_business_id, seller_business_id,
    ingredient_id, quantity, unit, unit_price_minor
) VALUES (
    'a7bce5e8-9bca-4dd9-bdb8-000000000046',
    'a7bce5e8-9bca-4dd9-bdb8-000000000045',
    'a7bce5e8-9bca-4dd9-bdb8-000000000001',
    'a7bce5e8-9bca-4dd9-bdb8-000000000002',
    'a7bce5e8-9bca-4dd9-bdb8-000000000042', 1, 'each', 1000
);

INSERT INTO public.network_order_dispatches (
    id, sales_order_id, buyer_business_id, seller_business_id,
    dispatch_number, status
) VALUES (
    'a7bce5e8-9bca-4dd9-bdb8-000000000047',
    'a7bce5e8-9bca-4dd9-bdb8-000000000045',
    'a7bce5e8-9bca-4dd9-bdb8-000000000001',
    'a7bce5e8-9bca-4dd9-bdb8-000000000002',
    'TEST-DISPATCH-SETTLEMENT', 'delivered'
);

INSERT INTO public.network_order_dispatch_lines (
    id, dispatch_id, sales_order_line_id, buyer_business_id,
    seller_business_id, quantity, unit
) VALUES (
    'a7bce5e8-9bca-4dd9-bdb8-000000000048',
    'a7bce5e8-9bca-4dd9-bdb8-000000000047',
    'a7bce5e8-9bca-4dd9-bdb8-000000000046',
    'a7bce5e8-9bca-4dd9-bdb8-000000000001',
    'a7bce5e8-9bca-4dd9-bdb8-000000000002', 1, 'each'
);

INSERT INTO public.network_dispatched_receipts (
    id, dispatch_id, buyer_business_id, seller_business_id,
    receipt_status, received_quantity, unit
) VALUES (
    'a7bce5e8-9bca-4dd9-bdb8-000000000049',
    'a7bce5e8-9bca-4dd9-bdb8-000000000047',
    'a7bce5e8-9bca-4dd9-bdb8-000000000001',
    'a7bce5e8-9bca-4dd9-bdb8-000000000002', 'committed', 1, 'each'
);

INSERT INTO public.financial_accounts (
    id, business_id, account_code, account_name, account_type,
    currency, balance_minor, available_minor
) VALUES (
    'a7bce5e8-9bca-4dd9-bdb8-000000000050',
    'a7bce5e8-9bca-4dd9-bdb8-000000000001',
    'CASH', 'Settlement test buyer cash', 'Asset', 'AED', 10000, 10000
);

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

    -- Execute a genuine invoice through route reservation, finality, ledger
    -- posting, liquidity consumption and final route completion.
    v_error := NULL;
    v_route_id := NULL;
    DECLARE
        v_invoice_id uuid;
        v_batch_id uuid;
        v_gate_id uuid;
        v_source_id uuid;
        v_ledger_count bigint;
    BEGIN
        v_invoice_id := public.v32_three_way_match(
            'a7bce5e8-9bca-4dd9-bdb8-000000000044',
            'a7bce5e8-9bca-4dd9-bdb8-000000000048',
            'a7bce5e8-9bca-4dd9-bdb8-000000000049',
            0
        );

        v_batch_id := public.v32_compile_settlement_batch(ARRAY[v_invoice_id]);
        v_source_id := public.network_register_liquidity_source(
            'a7bce5e8-9bca-4dd9-bdb8-000000000001',
            'a7bce5e8-9bca-4dd9-bdb8-000000000050',
            10000,
            1
        );
        v_route_id := public.network_compile_settlement_route(v_batch_id);
        PERFORM public.network_authorize_settlement_route(v_route_id);
        v_gate_id := public.network_create_financial_finality_gate(
            v_batch_id, v_route_id, '[]'::jsonb
        );
        IF public.network_evaluate_financial_finality_gate(v_gate_id) <> 'verified' THEN
            RAISE EXCEPTION 'positive-path finality gate did not verify';
        END IF;

        v_route_id := public.network_execute_settlement_route(v_route_id);

        IF (SELECT state FROM public.network_settlement_routes WHERE route_id=v_route_id) <> 'completed' THEN
            RAISE EXCEPTION 'successful execution did not complete the route';
        END IF;
        IF (SELECT state FROM public.settlement_batches WHERE id=v_batch_id) <> 'reconciled' THEN
            RAISE EXCEPTION 'successful execution did not reconcile the batch';
        END IF;
        IF (SELECT status FROM public.network_invoices WHERE id=v_invoice_id) <> 'settled' THEN
            RAISE EXCEPTION 'successful execution did not settle the invoice';
        END IF;
        IF (SELECT state FROM public.network_financial_finality_gates WHERE gate_id=v_gate_id) <> 'consumed' THEN
            RAISE EXCEPTION 'successful execution did not consume the finality gate';
        END IF;
        IF EXISTS (SELECT 1 FROM public.network_liquidity_reservations WHERE route_id=v_route_id AND state <> 'consumed') THEN
            RAISE EXCEPTION 'successful execution left an unconsumed reservation';
        END IF;
        IF (SELECT reserved_minor FROM public.network_liquidity_sources WHERE liquidity_source_id=v_source_id) <> 0 THEN
            RAISE EXCEPTION 'successful execution did not release the reserved capacity';
        END IF;
        IF (SELECT balance_minor FROM public.financial_accounts WHERE id='a7bce5e8-9bca-4dd9-bdb8-000000000050') <> 9000 THEN
            RAISE EXCEPTION 'buyer cash balance does not reflect settlement';
        END IF;
        IF (SELECT balance_minor FROM public.financial_accounts WHERE business_id='a7bce5e8-9bca-4dd9-bdb8-000000000002' AND account_code='CASH' AND currency='AED') <> 1000 THEN
            RAISE EXCEPTION 'seller cash balance does not reflect settlement';
        END IF;

        SELECT count(*) INTO v_ledger_count FROM public.financial_ledger_entries;
        PERFORM public.network_execute_settlement_route(v_route_id);
        IF (SELECT count(*) FROM public.financial_ledger_entries) <> v_ledger_count THEN
            RAISE EXCEPTION 'idempotent retry posted duplicate ledger entries';
        END IF;
    END;
END
$settlement_assertions$;

ROLLBACK;

SELECT 'PASS: settlement execution boundary and rollback contracts verified' AS result;
