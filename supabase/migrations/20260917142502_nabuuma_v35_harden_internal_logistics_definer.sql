CREATE OR REPLACE FUNCTION public.record_v22_logistics_milestone(
  p_shipment_id uuid,
  p_milestone_code text,
  p_occurred_at timestamptz DEFAULT now(),
  p_source text DEFAULT 'user',
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  s public.v22_logistics_shipments;
  m_id uuid;
  current_rank integer;
  new_rank integer;
BEGIN
  SELECT * INTO s
  FROM public.v22_logistics_shipments
  WHERE id = p_shipment_id
  FOR UPDATE;

  IF s.id IS NULL THEN
    RAISE EXCEPTION 'Shipment not found';
  END IF;

  IF NOT public.has_role(
    s.business_id,
    ARRAY['owner','manager','staff']::public.member_role[]
  ) THEN
    RAISE EXCEPTION 'Not authorized for this business' USING ERRCODE = '42501';
  END IF;

  IF p_milestone_code NOT IN (
    'planned','supplier_confirmed','dispatched','in_transit',
    'out_for_delivery','delivered','exception'
  ) THEN
    RAISE EXCEPTION 'Unsupported milestone' USING ERRCODE = '23514';
  END IF;

  current_rank := CASE s.status
    WHEN 'planned' THEN 1
    WHEN 'confirmed' THEN 2
    WHEN 'in_transit' THEN 4
    WHEN 'out_for_delivery' THEN 5
    WHEN 'delivered' THEN 6
    WHEN 'exception' THEN 7
    ELSE 1
  END;

  new_rank := CASE p_milestone_code
    WHEN 'planned' THEN 1
    WHEN 'supplier_confirmed' THEN 2
    WHEN 'dispatched' THEN 3
    WHEN 'in_transit' THEN 4
    WHEN 'out_for_delivery' THEN 5
    WHEN 'delivered' THEN 6
    WHEN 'exception' THEN 7
  END;

  IF new_rank < current_rank AND p_milestone_code <> 'exception' THEN
    RAISE EXCEPTION 'Milestone cannot move shipment backwards' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.v22_logistics_milestones (
    business_id,
    shipment_id,
    milestone_code,
    occurred_at,
    source,
    notes,
    created_by
  ) VALUES (
    s.business_id,
    s.id,
    p_milestone_code,
    p_occurred_at,
    p_source,
    p_notes,
    auth.uid()
  )
  RETURNING id INTO m_id;

  UPDATE public.v22_logistics_shipments
  SET
    status = CASE p_milestone_code
      WHEN 'supplier_confirmed' THEN 'confirmed'
      WHEN 'dispatched' THEN 'in_transit'
      WHEN 'in_transit' THEN 'in_transit'
      WHEN 'out_for_delivery' THEN 'out_for_delivery'
      WHEN 'delivered' THEN 'delivered'
      WHEN 'exception' THEN 'exception'
      ELSE status
    END,
    confirmed_at = CASE
      WHEN p_milestone_code = 'supplier_confirmed'
      THEN coalesce(confirmed_at,p_occurred_at)
      ELSE confirmed_at
    END,
    dispatched_at = CASE
      WHEN p_milestone_code = 'dispatched'
      THEN coalesce(dispatched_at,p_occurred_at)
      ELSE dispatched_at
    END,
    delivered_at = CASE
      WHEN p_milestone_code = 'delivered'
      THEN coalesce(delivered_at,p_occurred_at)
      ELSE delivered_at
    END
  WHERE id = s.id;

  IF p_milestone_code = 'exception' THEN
    INSERT INTO public.v22_supply_exceptions (
      business_id,
      shipment_id,
      purchase_order_id,
      stock_transfer_id,
      exception_type,
      severity,
      details
    ) VALUES (
      s.business_id,
      s.id,
      s.purchase_order_id,
      s.stock_transfer_id,
      'route_blocked',
      'high',
      jsonb_build_object('milestone_id',m_id,'notes',p_notes)
    );
  END IF;

  RETURN m_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.record_v22_logistics_milestone(uuid,text,timestamptz,text,text) FROM PUBLIC, anon, authenticated;