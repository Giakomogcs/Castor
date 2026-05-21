-- file: 001_castor_bootstrap.sql
-- tier: A
-- purpose: Extensões, tabela de controle de versões e grants canônicos do schema auth.
-- depends: -
-- reversible: no
-- IDEMPOTENTE.

BEGIN;

-- Extensões necessárias por todo o resto do schema.
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid, crypt, gen_salt
CREATE EXTENSION IF NOT EXISTS vector;     -- pgvector (RAG)

-- Tabela de controle de versões de migration.
CREATE TABLE IF NOT EXISTS castor_schema_migrations (
  version    TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Restaura GRANTs canônicos em schema auth caso algum upgrade/migration os tenha revogado.
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

-- GoTrue não suporta RLS em auth.*. Garante OFF.
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

-- Helper de verificação de admin (usado por todas as RPCs admin).
-- Bypass automático quando conectado via role privilegiado (n8n direto / service_role),
-- caso contrário valida pelo JWT do Supabase (auth.uid()).
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
  -- n8n se conecta como postgres/service_role/supabase_admin → confia
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

GRANT EXECUTE ON FUNCTION castor_is_admin() TO authenticated;

INSERT INTO castor_schema_migrations(version) VALUES ('001_bootstrap') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';
