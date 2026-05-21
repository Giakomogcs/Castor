-- file: 001_ext_and_helpers.sql
-- tier: A
-- purpose: Extensões, tabela de versão de migrations, grants canônicos auth, helpers castor_is_admin / castor_assert_admin.
-- depends: -
-- IDEMPOTENTE.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS castor_schema_migrations (
  version    TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA auth TO supabase_auth_admin';
    EXECUTE 'GRANT ALL ON ALL TABLES    IN SCHEMA auth TO supabase_auth_admin';
    EXECUTE 'GRANT ALL ON ALL SEQUENCES IN SCHEMA auth TO supabase_auth_admin';
    EXECUTE 'GRANT ALL ON ALL FUNCTIONS IN SCHEMA auth TO supabase_auth_admin';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT ALL ON TABLES    TO supabase_auth_admin';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT ALL ON SEQUENCES TO supabase_auth_admin';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT ALL ON FUNCTIONS TO supabase_auth_admin';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA auth TO authenticator, anon, authenticated, service_role';
  END IF;
END
$$;

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.oid::regclass AS rel
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'auth' AND c.relkind = 'r' AND c.relrowsecurity = true
  LOOP
    EXECUTE format('ALTER TABLE %s DISABLE ROW LEVEL SECURITY', r.rel);
  END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION castor_is_admin()
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = auth, public, pg_temp
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_user TEXT := current_user;
  v_uid  UUID;
BEGIN
  IF v_user IN ('postgres', 'service_role', 'supabase_admin', 'supabase_auth_admin') THEN
    RETURN TRUE;
  END IF;
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
  END;
  IF v_uid IS NULL THEN
    RETURN FALSE;
  END IF;
  RETURN COALESCE(
    (SELECT raw_user_meta_data->>'role'
       FROM auth.users
      WHERE id = v_uid) = 'admin',
    FALSE
  );
END;
$$;

CREATE OR REPLACE FUNCTION castor_assert_admin(p_caller UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE v_role TEXT;
BEGIN
  IF p_caller IS NULL THEN
    RAISE EXCEPTION 'caller obrigatorio' USING ERRCODE='22023';
  END IF;
  SELECT COALESCE(u.raw_user_meta_data->>'role','vendedor')
    INTO v_role FROM auth.users u WHERE u.id = p_caller;
  IF v_role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'forbidden: admin-only' USING ERRCODE='42501';
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION castor_is_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION castor_assert_admin(UUID) TO authenticated, service_role;

INSERT INTO castor_schema_migrations(version)
VALUES ('001_ext_and_helpers') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ========================== DOWN (comentado) ==========================
-- BEGIN;
-- DROP FUNCTION IF EXISTS castor_assert_admin(UUID);
-- DROP FUNCTION IF EXISTS castor_is_admin();
-- DROP TABLE IF EXISTS castor_schema_migrations;
-- -- Não derrubar extensões em produção compartilhada:
-- -- DROP EXTENSION IF EXISTS vector;
-- -- DROP EXTENSION IF EXISTS pgcrypto;
-- COMMIT;
