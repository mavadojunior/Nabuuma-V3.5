-- Create a disposable table whose DML privileges are granted only to PUBLIC.
-- Revoke bootstrap defaults first so this probe isolates inherited PUBLIC DML.
CREATE TABLE public.acl_public_dml_probe (id bigint);
REVOKE INSERT, UPDATE, DELETE ON TABLE public.acl_public_dml_probe
FROM anon, authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON TABLE public.acl_public_dml_probe TO PUBLIC;
