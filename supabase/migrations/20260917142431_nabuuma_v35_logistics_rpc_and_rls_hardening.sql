BEGIN;

-- Controlled logistics write boundary. RLS remains enabled as defense in depth.
ALTER TABLE public.v22_logistics_shipments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.v22_logistics_milestones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_logistics_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_delivery_commitments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.network_dispatched_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gcc_cross_border_pod ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gcc_cross_border_manifests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gcc_cross_border_manifest_lines ENABLE ROW LEVEL SECURITY;

-- Remove inherited/default client reachability before granting the exact API surface.
REVOKE ALL ON TABLE public.v22_logistics_shipments FROM anon, authenticated;
REVOKE ALL ON TABLE public.v22_logistics_milestones FROM anon, authenticated;
REVOKE ALL ON TABLE public.supplier_logistics_events FROM anon, authenticated;
REVOKE ALL ON TABLE public.supplier_delivery_commitments FROM anon, authenticated;
REVOKE ALL ON TABLE public.network_dispatched_receipts FROM anon, authenticated;
REVOKE ALL ON TABLE public.gcc_cross_border_pod FROM anon, authenticated;
REVOKE ALL ON TABLE public.gcc_cross_border_manifests FROM anon;
REVOKE ALL ON TABLE public.gcc_cross_border_manifest_lines FROM anon;

-- Read surface for signed-in clients.
GRANT SELECT ON TABLE public.v22_logistics_shipments TO authenticated;
GRANT SELECT ON TABLE public.v22_logistics_milestones TO authenticated;
GRANT SELECT ON TABLE public.supplier_logistics_events TO authenticated;
GRANT SELECT ON TABLE public.supplier_delivery_commitments TO authenticated;
GRANT SELECT ON TABLE public.network_dispatched_receipts TO authenticated;
GRANT SELECT ON TABLE public.gcc_cross_border_pod TO authenticated;
GRANT SELECT ON TABLE public.gcc_cross_border_manifests TO authenticated;
GRANT SELECT ON TABLE public.gcc_cross_border_manifest_lines TO authenticated;

-- Append-only/direct collaborative writes permitted only where explicitly intended.
GRANT INSERT ON TABLE public.supplier_logistics_events TO authenticated;
GRANT INSERT ON TABLE public.supplier_delivery_commitments TO authenticated;
GRANT INSERT ON TABLE public.network_dispatched_receipts TO authenticated;

-- Explicitly remove client mutation from the lifecycle tables and POD.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.v22_logistics_shipments FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.v22_logistics_milestones FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.gcc_cross_border_pod FROM anon, authenticated;
REVOKE UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.supplier_logistics_events FROM anon, authenticated;
REVOKE UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.supplier_delivery_commitments FROM anon, authenticated;
REVOKE UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.network_dispatched_receipts FROM anon, authenticated;

-- Replace only the controlled-write policies created by this layer.
DROP POLICY IF EXISTS v22_shipment_insert_member ON public.v22_logistics_shipments;
DROP POLICY IF EXISTS v22_shipment_update_member ON public.v22_logistics_shipments;
DROP POLICY IF EXISTS v22_milestone_insert_member ON public.v22_logistics_milestones;
DROP POLICY IF EXISTS v22_milestone_update_member ON public.v22_logistics_milestones;
DROP POLICY IF EXISTS v22_logistics_event_insert_member ON public.supplier_logistics_events;
DROP POLICY IF EXISTS v22_commitment_insert_member ON public.supplier_delivery_commitments;
DROP POLICY IF EXISTS network_receipt_insert_member ON public.network_dispatched_receipts;
DROP POLICY IF EXISTS gcc_pod_insert_member ON public.gcc_cross_border_pod;

-- Direct append-only policies.
CREATE POLICY v22_logistics_event_insert_member
ON public.supplier_logistics_events
FOR INSERT TO authenticated
WITH CHECK ((select public.is_member(business_id)));

CREATE POLICY v22_commitment_insert_member
ON public.supplier_delivery_commitments
FOR INSERT TO authenticated
WITH CHECK ((select public.is_member(business_id)));

CREATE POLICY network_receipt_insert_member
ON public.network_dispatched_receipts
FOR INSERT TO authenticated
WITH CHECK (
  (select public.is_member(buyer_business_id))
  OR (select public.is_member(seller_business_id))
);

-- Lifecycle tables intentionally have no direct authenticated INSERT/UPDATE policy.
-- Their mutation path is the SECURITY DEFINER RPC below.

CREATE OR REPLACE FUNCTION public.v22_upsert_shipment_milestone(
  p_shipment_id uuid,
  p_milestone_code text,
  p_occurred_at timestamptz DEFAULT now(),
  p_source text DEFAULT 'user',
  p_notes text DEFAULT NULL
)
RETURNS public.v22_logistics_milestones
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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

CREATE OR REPLACE FUNCTION public.v22_finalize_cross_border_pod(
  p_manifest_id uuid,
  p_dispatch_id uuid,
  p_delivered_at timestamptz,
  p_evidence_hash text
)
RETURNS public.gcc_cross_border_pod
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_manifest public.gcc_cross_border_manifests;
  v_dispatch public.network_order_dispatches;
  v_result public.gcc_cross_border_pod;
BEGIN
  IF (select auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'Authentication required.' USING ERRCODE = '42501';
  END IF;

  IF p_delivered_at IS NULL THEN
    RAISE EXCEPTION 'Delivered timestamp is required.' USING ERRCODE = '23514';
  END IF;

  IF p_evidence_hash IS NULL OR p_evidence_hash !~ '^[0-9a-fA-F]{64}$' THEN
    RAISE EXCEPTION 'Evidence hash must be a 64-character hexadecimal SHA-256 value.' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO v_manifest
  FROM public.gcc_cross_border_manifests
  WHERE manifest_id = p_manifest_id
  FOR UPDATE;

  IF v_manifest.manifest_id IS NULL THEN
    RAISE EXCEPTION 'Manifest not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    (select public.is_member(v_manifest.business_id))
    OR (select public.is_member(v_manifest.seller_business_id))
    OR (select public.is_member(v_manifest.buyer_business_id))
  ) THEN
    RAISE EXCEPTION 'Not authorized for manifest.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_dispatch
  FROM public.network_order_dispatches
  WHERE id = p_dispatch_id
  FOR UPDATE;

  IF v_dispatch.id IS NULL THEN
    RAISE EXCEPTION 'Dispatch not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    (select public.is_member(v_dispatch.buyer_business_id))
    OR (select public.is_member(v_dispatch.seller_business_id))
  ) THEN
    RAISE EXCEPTION 'Not authorized for dispatch.' USING ERRCODE = '42501';
  END IF;

  IF NOT (
    v_dispatch.buyer_business_id = v_manifest.buyer_business_id
    AND v_dispatch.seller_business_id = v_manifest.seller_business_id
  ) THEN
    RAISE EXCEPTION 'Structural Invariant Failure: Dispatch participants do not match manifest.' USING ERRCODE = '23514';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.gcc_cross_border_manifest_lines ml
    WHERE ml.manifest_id = p_manifest_id
      AND ml.source_dispatch_id = p_dispatch_id
  ) THEN
    RAISE EXCEPTION 'Structural Invariant Failure: Dispatch is not linked to manifest lines.' USING ERRCODE = '23514';
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
    (select auth.uid()),
    lower(p_evidence_hash),
    'submitted'
  )
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$function$;

-- Underlying privileged function is not a client API.
REVOKE EXECUTE ON FUNCTION public.record_v22_logistics_milestone(uuid,text,timestamptz,text,text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.v22_upsert_shipment_milestone(uuid,text,timestamptz,text,text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.v22_finalize_cross_border_pod(uuid,uuid,timestamptz,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v22_upsert_shipment_milestone(uuid,text,timestamptz,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.v22_finalize_cross_border_pod(uuid,uuid,timestamptz,text) TO authenticated;

COMMIT;