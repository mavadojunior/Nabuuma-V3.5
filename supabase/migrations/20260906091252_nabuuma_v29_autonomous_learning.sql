BEGIN;

CREATE TABLE IF NOT EXISTS public.v29_learning_outcomes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL,
  decision_id uuid,
  source_type text NOT NULL CHECK (source_type IN ('replenishment','routing','supplier','transfer','exception')),
  source_id uuid,
  outcome_type text NOT NULL,
  predicted_value numeric(24,8),
  actual_value numeric(24,8),
  unit text,
  error_value numeric(24,8),
  confidence numeric(6,5) CHECK (confidence >= 0 AND confidence <= 1),
  observed_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.v29_policy_candidates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL,
  policy_key text NOT NULL,
  policy_version integer NOT NULL CHECK (policy_version > 0),
  parameters jsonb NOT NULL,
  evidence_count integer NOT NULL DEFAULT 0 CHECK (evidence_count >= 0),
  score numeric(24,8) NOT NULL,
  status text NOT NULL DEFAULT 'candidate' CHECK (status IN ('candidate','approved','rejected','retired')),
  created_at timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz,
  approved_by uuid,
  UNIQUE (business_id, policy_key, policy_version)
);

CREATE TABLE IF NOT EXISTS public.v29_policy_evaluations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL,
  policy_candidate_id uuid NOT NULL REFERENCES public.v29_policy_candidates(id),
  baseline_score numeric(24,8) NOT NULL,
  candidate_score numeric(24,8) NOT NULL,
  sample_count integer NOT NULL CHECK (sample_count >= 0),
  improvement numeric(24,8) NOT NULL,
  evaluated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (policy_candidate_id)
);

CREATE INDEX IF NOT EXISTS idx_v29_learning_business_observed ON public.v29_learning_outcomes(business_id, observed_at DESC);
CREATE INDEX IF NOT EXISTS idx_v29_candidates_business_policy ON public.v29_policy_candidates(business_id, policy_key, status);

ALTER TABLE public.v29_learning_outcomes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.v29_policy_candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.v29_policy_evaluations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS v29_learning_member_select ON public.v29_learning_outcomes;
CREATE POLICY v29_learning_member_select ON public.v29_learning_outcomes FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.business_members bm WHERE bm.business_id = v29_learning_outcomes.business_id AND bm.user_id = auth.uid()));
DROP POLICY IF EXISTS v29_candidates_member_select ON public.v29_policy_candidates;
CREATE POLICY v29_candidates_member_select ON public.v29_policy_candidates FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.business_members bm WHERE bm.business_id = v29_policy_candidates.business_id AND bm.user_id = auth.uid()));
DROP POLICY IF EXISTS v29_evaluations_member_select ON public.v29_policy_evaluations;
CREATE POLICY v29_evaluations_member_select ON public.v29_policy_evaluations FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.business_members bm WHERE bm.business_id = v29_policy_evaluations.business_id AND bm.user_id = auth.uid()));

REVOKE INSERT, UPDATE, DELETE ON public.v29_learning_outcomes FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON public.v29_policy_candidates FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON public.v29_policy_evaluations FROM authenticated, anon;

CREATE OR REPLACE FUNCTION public.v29_record_learning_outcome(
  p_business_id uuid,
  p_source_type text,
  p_outcome_type text,
  p_actual_value numeric,
  p_predicted_value numeric DEFAULT NULL,
  p_unit text DEFAULT NULL,
  p_source_id uuid DEFAULT NULL,
  p_decision_id uuid DEFAULT NULL,
  p_confidence numeric DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  IF p_business_id IS NULL OR p_actual_value IS NULL THEN RAISE EXCEPTION 'business_id and actual_value are required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM business_members WHERE business_id=p_business_id AND user_id=auth.uid() AND role IN ('owner','manager')) AND auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  INSERT INTO v29_learning_outcomes(business_id,decision_id,source_type,source_id,outcome_type,predicted_value,actual_value,unit,error_value,confidence)
  VALUES(p_business_id,p_decision_id,p_source_type,p_source_id,p_outcome_type,p_predicted_value,p_actual_value,p_unit,
         CASE WHEN p_predicted_value IS NULL THEN NULL ELSE p_actual_value-p_predicted_value END,p_confidence)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

CREATE OR REPLACE FUNCTION public.v29_evaluate_policy_candidate(
  p_candidate_id uuid,
  p_baseline_score numeric,
  p_candidate_score numeric,
  p_sample_count integer
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_business uuid;
BEGIN
  SELECT business_id INTO v_business FROM v29_policy_candidates WHERE id=p_candidate_id FOR UPDATE;
  IF v_business IS NULL THEN RAISE EXCEPTION 'candidate not found'; END IF;
  IF auth.uid() IS NOT NULL AND NOT EXISTS (SELECT 1 FROM business_members WHERE business_id=v_business AND user_id=auth.uid() AND role IN ('owner','manager')) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_sample_count < 1 THEN RAISE EXCEPTION 'sample_count must be positive'; END IF;
  INSERT INTO v29_policy_evaluations(business_id,policy_candidate_id,baseline_score,candidate_score,sample_count,improvement)
  VALUES(v_business,p_candidate_id,p_baseline_score,p_candidate_score,p_sample_count,p_candidate_score-p_baseline_score)
  ON CONFLICT(policy_candidate_id) DO UPDATE SET baseline_score=EXCLUDED.baseline_score,candidate_score=EXCLUDED.candidate_score,sample_count=EXCLUDED.sample_count,improvement=EXCLUDED.improvement,evaluated_at=now()
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

CREATE OR REPLACE FUNCTION public.v29_approve_policy_candidate(p_candidate_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_business uuid; v_improvement numeric; v_samples integer;
BEGIN
  SELECT c.business_id, e.improvement, e.sample_count INTO v_business,v_improvement,v_samples
  FROM v29_policy_candidates c LEFT JOIN v29_policy_evaluations e ON e.policy_candidate_id=c.id
  WHERE c.id=p_candidate_id FOR UPDATE OF c;
  IF v_business IS NULL THEN RAISE EXCEPTION 'candidate not found'; END IF;
  IF auth.uid() IS NOT NULL AND NOT EXISTS (SELECT 1 FROM business_members WHERE business_id=v_business AND user_id=auth.uid() AND role IN ('owner','manager')) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF v_improvement IS NULL OR v_samples < 10 OR v_improvement <= 0 THEN RAISE EXCEPTION 'candidate lacks sufficient positive evidence'; END IF;
  UPDATE v29_policy_candidates SET status='approved', approved_at=now(), approved_by=auth.uid() WHERE id=p_candidate_id;
END; $$;

CREATE OR REPLACE VIEW public.view_v29_learning_control_tower AS
SELECT c.id,c.business_id,c.policy_key,c.policy_version,c.parameters,c.evidence_count,c.score,c.status,e.sample_count,e.improvement,e.evaluated_at
FROM public.v29_policy_candidates c LEFT JOIN public.v29_policy_evaluations e ON e.policy_candidate_id=c.id;

REVOKE ALL ON public.v29_learning_outcomes FROM anon;
REVOKE ALL ON public.v29_policy_candidates FROM anon;
REVOKE ALL ON public.v29_policy_evaluations FROM anon;
REVOKE ALL ON public.view_v29_learning_control_tower FROM anon;
GRANT SELECT ON public.v29_learning_outcomes, public.v29_policy_candidates, public.v29_policy_evaluations, public.view_v29_learning_control_tower TO authenticated;
GRANT EXECUTE ON FUNCTION public.v29_record_learning_outcome(uuid,text,text,numeric,numeric,text,uuid,uuid,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.v29_evaluate_policy_candidate(uuid,numeric,numeric,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.v29_approve_policy_candidate(uuid) TO authenticated;

COMMIT;