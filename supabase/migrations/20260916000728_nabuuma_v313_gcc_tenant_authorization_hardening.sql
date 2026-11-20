begin;

-- V3.13: replace the V3.6 auth.uid() == business_id assumption with the
-- canonical tenant model: public.business_members(business_id,user_id).

DROP POLICY IF EXISTS gcc_manifest_authenticated_select ON public.gcc_cross_border_manifests;
DROP POLICY IF EXISTS gcc_manifest_lines_authenticated_select ON public.gcc_cross_border_manifest_lines;
DROP POLICY IF EXISTS gcc_customs_events_authenticated_select ON public.gcc_customs_events;
DROP POLICY IF EXISTS gcc_escrow_authenticated_select ON public.gcc_cross_border_escrow;
DROP POLICY IF EXISTS gcc_pod_authenticated_select ON public.gcc_cross_border_pod;

CREATE POLICY gcc_manifest_authenticated_select
ON public.gcc_cross_border_manifests
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.business_members bm
    WHERE bm.business_id = gcc_cross_border_manifests.business_id
      AND bm.user_id = (SELECT auth.uid())
  )
  OR EXISTS (
    SELECT 1
    FROM public.business_members bm
    WHERE bm.business_id = gcc_cross_border_manifests.seller_business_id
      AND bm.user_id = (SELECT auth.uid())
  )
  OR EXISTS (
    SELECT 1
    FROM public.business_members bm
    WHERE bm.business_id = gcc_cross_border_manifests.buyer_business_id
      AND bm.user_id = (SELECT auth.uid())
  )
);

CREATE POLICY gcc_manifest_lines_authenticated_select
ON public.gcc_cross_border_manifest_lines
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.gcc_cross_border_manifests m
    WHERE m.manifest_id = gcc_cross_border_manifest_lines.manifest_id
      AND (
        EXISTS (
          SELECT 1 FROM public.business_members bm
          WHERE bm.business_id = m.business_id AND bm.user_id = (SELECT auth.uid())
        )
        OR EXISTS (
          SELECT 1 FROM public.business_members bm
          WHERE bm.business_id = m.seller_business_id AND bm.user_id = (SELECT auth.uid())
        )
        OR EXISTS (
          SELECT 1 FROM public.business_members bm
          WHERE bm.business_id = m.buyer_business_id AND bm.user_id = (SELECT auth.uid())
        )
      )
  )
);

CREATE POLICY gcc_customs_events_authenticated_select
ON public.gcc_customs_events
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.gcc_cross_border_manifests m
    WHERE m.manifest_id = gcc_customs_events.manifest_id
      AND (
        EXISTS (
          SELECT 1 FROM public.business_members bm
          WHERE bm.business_id = m.business_id AND bm.user_id = (SELECT auth.uid())
        )
        OR EXISTS (
          SELECT 1 FROM public.business_members bm
          WHERE bm.business_id = m.seller_business_id AND bm.user_id = (SELECT auth.uid())
        )
        OR EXISTS (
          SELECT 1 FROM public.business_members bm
          WHERE bm.business_id = m.buyer_business_id AND bm.user_id = (SELECT auth.uid())
        )
      )
  )
);

CREATE POLICY gcc_escrow_authenticated_select
ON public.gcc_cross_border_escrow
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.gcc_cross_border_manifests m
    WHERE m.manifest_id = gcc_cross_border_escrow.manifest_id
      AND (
        EXISTS (
          SELECT 1 FROM public.business_members bm
          WHERE bm.business_id = m.business_id AND bm.user_id = (SELECT auth.uid())
        )
        OR EXISTS (
          SELECT 1 FROM public.business_members bm
          WHERE bm.business_id = m.seller_business_id AND bm.user_id = (SELECT auth.uid())
        )
        OR EXISTS (
          SELECT 1 FROM public.business_members bm
          WHERE bm.business_id = m.buyer_business_id AND bm.user_id = (SELECT auth.uid())
        )
      )
  )
);

CREATE POLICY gcc_pod_authenticated_select
ON public.gcc_cross_border_pod
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.gcc_cross_border_manifests m
    WHERE m.manifest_id = gcc_cross_border_pod.manifest_id
      AND (
        EXISTS (
          SELECT 1 FROM public.business_members bm
          WHERE bm.business_id = m.business_id AND bm.user_id = (SELECT auth.uid())
        )
        OR EXISTS (
          SELECT 1 FROM public.business_members bm
          WHERE bm.business_id = m.seller_business_id AND bm.user_id = (SELECT auth.uid())
        )
        OR EXISTS (
          SELECT 1 FROM public.business_members bm
          WHERE bm.business_id = m.buyer_business_id AND bm.user_id = (SELECT auth.uid())
        )
      )
  )
);

-- Policy predicates are membership joins; index them for scale.
CREATE INDEX IF NOT EXISTS business_members_user_business_idx
ON public.business_members (user_id, business_id);

commit;