-- file: 003_castor_chat.sql
-- tier: A
-- purpose: Tabelas de chat (sessões + mensagens) compatíveis com o nó
--          memoryPostgresChat do n8n + RPC de carimbo de user_id.
-- depends: 001
-- reversible: no
-- IDEMPOTENTE. Self-healing: ALTER ADD COLUMN IF NOT EXISTS garante user_id
--             mesmo se o n8n criou a tabela antes desta migration rodar.

BEGIN;

-- SESSÕES -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS castor_chat_session (
  session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID,
  title      TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE castor_chat_session ADD COLUMN IF NOT EXISTS user_id    UUID;
ALTER TABLE castor_chat_session ADD COLUMN IF NOT EXISTS title      TEXT;
ALTER TABLE castor_chat_session ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE castor_chat_session ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
CREATE INDEX IF NOT EXISTS castor_chat_session_user_idx ON castor_chat_session(user_id);

-- MENSAGENS ---------------------------------------------------------
-- session_id é TEXT (compat com o que o memoryPostgresChat cria automaticamente).
CREATE TABLE IF NOT EXISTS castor_chat_message (
  id         BIGSERIAL PRIMARY KEY,
  session_id TEXT NOT NULL,
  user_id    UUID,
  message    JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE castor_chat_message ADD COLUMN IF NOT EXISTS user_id    UUID;
ALTER TABLE castor_chat_message ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
CREATE INDEX IF NOT EXISTS castor_chat_message_session_idx ON castor_chat_message(session_id);
CREATE INDEX IF NOT EXISTS castor_chat_message_user_idx    ON castor_chat_message(user_id);

-- CARIMBO DE user_id ------------------------------------------------
-- memoryPostgresChat insere {session_id, message} sem user_id.
-- Esta RPC é chamada em paralelo pelo workflow para preencher.
CREATE OR REPLACE FUNCTION castor_chat_stamp_user(
  p_session_id TEXT,
  p_user_id    UUID
)
RETURNS INTEGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_count INTEGER;
  v_uuid  UUID;
BEGIN
  IF p_session_id IS NULL OR p_session_id = '' OR p_user_id IS NULL THEN
    RETURN 0;
  END IF;

  UPDATE castor_chat_message
     SET user_id = p_user_id
   WHERE session_id::text = p_session_id
     AND user_id IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Tenta refletir na tabela de sessões (somente se session_id parsear como UUID).
  BEGIN
    v_uuid := p_session_id::uuid;
    INSERT INTO castor_chat_session(session_id, user_id)
    VALUES (v_uuid, p_user_id)
    ON CONFLICT (session_id) DO UPDATE
      SET user_id    = COALESCE(castor_chat_session.user_id, EXCLUDED.user_id),
          updated_at = NOW();
  EXCEPTION WHEN invalid_text_representation THEN
    -- session_id não é UUID; segue sem registrar em castor_chat_session.
    NULL;
  END;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION castor_chat_stamp_user(TEXT, UUID) TO authenticated;

INSERT INTO castor_schema_migrations(version) VALUES ('003_chat') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';
