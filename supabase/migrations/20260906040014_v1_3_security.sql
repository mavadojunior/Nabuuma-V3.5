CREATE TABLE IF NOT EXISTS public.users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text UNIQUE NOT NULL, full_name text, role text NOT NULL DEFAULT 'user', created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
CREATE OR REPLACE FUNCTION public.current_user_id() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT auth.uid() $$;
CREATE OR REPLACE FUNCTION public.is_admin() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM public.users WHERE id=auth.uid() AND role='admin') $$;
