-- file: 004_castor_runtime.sql
-- tier: A
-- purpose:
--   Estado de runtime do agente que NÃO é espelho do Protheus:
--     * castor_cnpj_cache    — cache da Receita Federal (BrasilAPI/ReceitaWS, TTL 30 dias).
--     * castor_vendor_user   — mapeia auth.users → SA3010.a3_cod (vendedor logado).
--   Os dados-fonte do Protheus moram no Google Drive (pasta source) e são lidos
--   pelos workflows n8n diretamente; NÃO existem mais tabelas castor_src_* aqui.
-- depends: 001
-- reversible: yes
-- IDEMPOTENTE.

BEGIN;

-- ============================================================
-- CACHE DE CNPJ (TTL 30 dias)
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_cnpj_cache (
  cnpj                  TEXT PRIMARY KEY,
  razao_social          TEXT,
  porte                 TEXT,   -- mapping Castor: pequeno|medio|grande
  porte_rf              TEXT,   -- RF original: MEI|ME|EPP|DEMAIS|...
  cnae_principal        TEXT,
  situacao_cadastral    TEXT,
  payload               JSONB NOT NULL DEFAULT '{}'::jsonb,
  fetched_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at            TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '30 days')
);
CREATE INDEX IF NOT EXISTS castor_cnpj_cache_expires_idx ON castor_cnpj_cache(expires_at);

-- ============================================================
-- MAPEAMENTO auth.users → SA3010.a3_cod
-- ============================================================
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
GRANT EXECUTE ON FUNCTION castor_my_vendor_code()                  TO authenticated;

INSERT INTO castor_schema_migrations(version) VALUES ('004_runtime') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';
