-- Test-only fixture for the existing v3.15.7 audit assertion suite.
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES
 ('20000000-0000-0000-0000-000000000001','authenticated','authenticated','audit-owner@example.invalid','',now(),'{}','{}',now(),now()),
 ('20000000-0000-0000-0000-000000000002','authenticated','authenticated','audit-outsider@example.invalid','',now(),'{}','{}',now(),now())
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.businesses (id,name,currency,timezone)
VALUES
 ('10000000-0000-0000-0000-000000000001','Audit test tenant A','AED','Asia/Dubai'),
 ('10000000-0000-0000-0000-000000000002','Audit test tenant B','AED','Asia/Dubai')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.business_members (business_id,user_id,role)
VALUES ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','owner')
ON CONFLICT (business_id,user_id) DO NOTHING;
