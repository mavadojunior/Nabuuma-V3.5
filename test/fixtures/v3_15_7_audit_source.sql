-- Synthetic trigger source used only by the v3.15.7 audit assertion suite.
CREATE TABLE IF NOT EXISTS public.audit_source (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL
);
CREATE OR REPLACE FUNCTION public.test_audit_log_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.audit_logs (business_id, user_id, action)
  VALUES (NEW.business_id, NULL, 'trigger-write');
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.test_audit_log_trigger() OWNER TO postgres;
DROP TRIGGER IF EXISTS test_audit_source_audit ON public.audit_source;
CREATE TRIGGER test_audit_source_audit
AFTER INSERT ON public.audit_source
FOR EACH ROW EXECUTE FUNCTION public.test_audit_log_trigger();
GRANT INSERT ON TABLE public.audit_source TO authenticated;
ALTER TABLE public.audit_source ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS audit_source_member_insert ON public.audit_source;
CREATE POLICY audit_source_member_insert ON public.audit_source
  FOR INSERT TO authenticated
  WITH CHECK (public.is_member(business_id));
