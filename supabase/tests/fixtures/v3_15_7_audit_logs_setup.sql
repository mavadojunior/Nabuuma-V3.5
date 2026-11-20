\set ON_ERROR_STOP on
-- Isolated PostgreSQL 17 fixture matching the production audit_logs boundary.
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
CREATE SCHEMA auth;
GRANT USAGE ON SCHEMA auth TO PUBLIC;

CREATE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql STABLE
AS $function$
    SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
$function$;
GRANT EXECUTE ON FUNCTION auth.uid() TO PUBLIC;

CREATE TABLE public.business_members (
    business_id uuid NOT NULL,
    user_id uuid NOT NULL,
    PRIMARY KEY (business_id, user_id)
);

CREATE FUNCTION public.is_member(target_business uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
    SELECT EXISTS (
        SELECT 1
          FROM public.business_members AS bm
         WHERE bm.business_id = target_business
           AND bm.user_id = auth.uid()
    )
$function$;

CREATE TABLE public.audit_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id uuid NOT NULL,
    user_id uuid,
    action text NOT NULL,
    entity_type text,
    entity_id uuid,
    metadata jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Model the production SECURITY DEFINER trigger writers. Their audit rows may
-- have user_id NULL or may use a source-row actor, so they require trusted owner
-- execution rather than the authenticated-client INSERT policy.
CREATE TABLE public.audit_source (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id uuid NOT NULL
);

CREATE FUNCTION public.test_audit_log_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
    INSERT INTO public.audit_logs (business_id, user_id, action)
    VALUES (NEW.business_id, NULL, 'trigger-write');
    RETURN NEW;
END
$function$;

CREATE TRIGGER test_audit_source_audit
AFTER INSERT ON public.audit_source
FOR EACH ROW EXECUTE FUNCTION public.test_audit_log_trigger();

GRANT INSERT ON TABLE public.audit_source TO authenticated;

-- Reproduce the broad client ACL observed in production before V3.15.7.
GRANT ALL PRIVILEGES ON TABLE public.audit_logs
TO anon, authenticated, service_role;

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY audit_logs_select ON public.audit_logs
    FOR SELECT TO PUBLIC
    USING (public.is_member(business_id));

CREATE POLICY audit_write ON public.audit_logs
    FOR INSERT TO PUBLIC
    WITH CHECK (
        public.is_member(business_id)
        AND user_id = (SELECT auth.uid())
    );

CREATE POLICY audit_no_update ON public.audit_logs
    FOR UPDATE TO PUBLIC
    USING (false)
    WITH CHECK (false);

CREATE POLICY audit_no_delete ON public.audit_logs
    FOR DELETE TO PUBLIC
    USING (false);

INSERT INTO public.business_members (business_id, user_id)
VALUES (
    '10000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001'
);
