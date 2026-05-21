-- file: 004_runtime.sql
-- tier: A
-- purpose: Cache de CNPJ + mapeamento user_id ↔ código de vendedor Protheus (A3_COD).
-- depends: 001
-- IDEMPOTENTE.

BEGIN;

CREATE TABLE IF NOT EXISTS castor_cnpj_cache (
  cnpj                  TEXT PRIMARY KEY,
  razao_social          TEXT,
  porte                 TEXT,
  porte_rf              TEXT,
  cnae_principal        TEXT,
  situacao_cadastral    TEXT,
  payload               JSONB NOT NULL DEFAULT '{}'::jsonb,
  fetched_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at            TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '30 days')
);
CREATE INDEX IF NOT EXISTS castor_cnpj_cache_expires_idx ON castor_cnpj_cache(expires_at);

CREATE TABLE IF NOT EXISTS castor_vendor_user (
  user_id    UUID PRIMARY KEY,
  codigo     TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_vendor_user_codigo_idx ON castor_vendor_user(codigo);

CREATE OR REPLACE FUNCTION castor_admin_set_vendor_code(p_user_id UUID, p_codigo TEXT)
RETURNS VOID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT castor_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  INSERT INTO castor_vendor_user(user_id, codigo, updated_at)
  VALUES (p_user_id, p_codigo, NOW())
  ON CONFLICT (user_id) DO UPDATE SET codigo = EXCLUDED.codigo, updated_at = NOW();
END;
$$;

CREATE OR REPLACE FUNCTION castor_my_vendor_code()
RETURNS TEXT
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql STABLE
AS $$
  SELECT codigo FROM castor_vendor_user WHERE user_id = auth.uid();
$$;

GRANT EXECUTE ON FUNCTION castor_admin_set_vendor_code(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION castor_my_vendor_code() TO authenticated;

INSERT INTO castor_schema_migrations(version)
VALUES ('004_runtime') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ========================== DOWN (comentado) ==========================
-- BEGIN;
-- DROP FUNCTION IF EXISTS castor_my_vendor_code();
-- DROP FUNCTION IF EXISTS castor_admin_set_vendor_code(UUID, TEXT);
-- DROP TABLE IF EXISTS castor_vendor_user;
-- DROP TABLE IF EXISTS castor_cnpj_cache;
-- COMMIT;
