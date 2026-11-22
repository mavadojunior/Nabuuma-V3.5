-- TEST-ONLY Supabase compatibility bootstrap for native PostgreSQL 17.
-- Never apply this file to a hosted Supabase project or production database.
\set ON_ERROR_STOP on

DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'postgres') THEN
    CREATE ROLE postgres WITH LOGIN SUPERUSER CREATEDB CREATEROLE INHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE ROLE supabase_auth_admin NOLOGIN BYPASSRLS;
  END IF;
END
$roles$;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE SCHEMA IF NOT EXISTS auth;
GRANT USAGE ON SCHEMA public, extensions, auth TO anon, authenticated, service_role, supabase_auth_admin;

-- Supabase migration history expects pgcrypto in public for unqualified digest(),
-- while later functions explicitly qualify extensions.digest(). Install once in
-- public and expose equivalent test-only wrappers in extensions.
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;
CREATE OR REPLACE FUNCTION extensions.digest(text, text)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT public.digest($1, $2) $$;
CREATE OR REPLACE FUNCTION extensions.digest(bytea, text)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$ SELECT public.digest($1, $2) $$;

CREATE OR REPLACE FUNCTION extensions.gen_random_uuid()
RETURNS uuid LANGUAGE sql VOLATILE PARALLEL SAFE
AS $$ SELECT pg_catalog.gen_random_uuid() $$;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY,
  instance_id uuid,
  aud text,
  role text,
  email text,
  encrypted_password text,
  email_confirmed_at timestamptz,
  raw_app_meta_data jsonb,
  raw_user_meta_data jsonb,
  created_at timestamptz,
  updated_at timestamptz
);

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql STABLE
AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql STABLE
AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    auth.jwt() ->> 'role'
  )
$$;

GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.jwt() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.role() TO anon, authenticated, service_role;
GRANT SELECT ON auth.users TO authenticated, service_role, supabase_auth_admin;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO authenticated, service_role;

SELECT 'supabase_test_shim_ready' AS status;
