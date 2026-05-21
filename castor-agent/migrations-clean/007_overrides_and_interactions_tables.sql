-- file: 007_overrides_and_interactions_tables.sql
-- tier: A
-- purpose: Tabelas castor_client_address_override (override editorial de endereço/contato/lifecycle por cliente)
--   e castor_client_interactions (histórico unificado). As FUNÇÕES que operam sobre essas tabelas
--   ficam em 010_routes_and_interactions_functions.sql (precisam de objetos definidos depois).
-- depends: 001
-- IDEMPOTENTE.

BEGIN;

CREATE TABLE IF NOT EXISTS castor_client_address_override (
  cliente_codigo   TEXT PRIMARY KEY,
  endereco         TEXT,
  cep              TEXT,
  municipio        TEXT,
  uf               TEXT,
  contato_nome     TEXT,
  contato_tel      TEXT,
  contato_email    TEXT,
  contato_whats    TEXT,
  lifecycle_status TEXT CHECK (lifecycle_status IN (
    'ativo','encerrado','nao_interessado_permanente'
  )),
  notes            TEXT,
  updated_by       UUID,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_client_address_override_mun_idx  ON castor_client_address_override(uf, municipio);
CREATE INDEX IF NOT EXISTS castor_client_address_override_life_idx ON castor_client_address_override(lifecycle_status);

CREATE OR REPLACE FUNCTION castor_client_address_override_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := NOW(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS castor_client_address_override_touch_trg ON castor_client_address_override;
CREATE TRIGGER castor_client_address_override_touch_trg
  BEFORE UPDATE ON castor_client_address_override
  FOR EACH ROW EXECUTE FUNCTION castor_client_address_override_touch();

CREATE TABLE IF NOT EXISTS castor_client_interactions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_codigo   TEXT NOT NULL,
  vendedor_user_id UUID,
  vendedor_codigo  TEXT,
  route_id         UUID,
  interaction_type TEXT NOT NULL CHECK (interaction_type IN (
    'visita_presencial','telefone','whatsapp','email','reuniao_online','outro'
  )),
  outcome          TEXT CHECK (outcome IN (
    'visitou','sem_contato','convertido','voltar_depois','negativo',
    'aguardando_resposta','pedido_em_negociacao',
    'nao_existe_mais','nao_interessado_permanente'
  )),
  notes            TEXT,
  occurred_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  next_contact_at  DATE,
  next_action      TEXT,
  idempotency_key  TEXT UNIQUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_client_interactions_cli_idx   ON castor_client_interactions(cliente_codigo, occurred_at DESC);
CREATE INDEX IF NOT EXISTS castor_client_interactions_user_idx  ON castor_client_interactions(vendedor_user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS castor_client_interactions_next_idx  ON castor_client_interactions(next_contact_at) WHERE next_contact_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS castor_client_interactions_route_idx ON castor_client_interactions(route_id) WHERE route_id IS NOT NULL;

INSERT INTO castor_schema_migrations(version)
VALUES ('007_overrides_and_interactions_tables') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ========================== DOWN (comentado) ==========================
-- BEGIN;
-- DROP TRIGGER IF EXISTS castor_client_address_override_touch_trg ON castor_client_address_override;
-- DROP FUNCTION IF EXISTS castor_client_address_override_touch();
-- DROP TABLE IF EXISTS castor_client_interactions;
-- DROP TABLE IF EXISTS castor_client_address_override;
-- COMMIT;
