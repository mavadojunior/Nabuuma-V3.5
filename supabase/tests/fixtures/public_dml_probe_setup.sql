-- Create a disposable table whose DML privileges are granted only to PUBLIC.
-- The ACL reconciliation migration must remove this inherited access.
CREATE TABLE public.acl_public_dml_probe (id bigint);
REVOKE INSERT, UPDATE, DELETE ON TABLE public.acl_public_dml_probe
FROM anon, authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON TABLE public.acl_public_dml_probe TO PUBLIC;
