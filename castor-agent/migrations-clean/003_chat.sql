-- file: 003_chat.sql
-- tier: A
-- purpose: Histórico do chat (sessões + mensagens) + stamp_user idempotente.
-- depends: 001
-- IDEMPOTENTE.

BEGIN;

CREATE TABLE IF NOT EXISTS castor_chat_session (
  session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID,
  title      TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_chat_session_user_idx ON castor_chat_session(user_id);

CREATE TABLE IF NOT EXISTS castor_chat_message (
  id         BIGSERIAL PRIMARY KEY,
  session_id TEXT NOT NULL,
  user_id    UUID,
  message    JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_chat_message_session_idx ON castor_chat_message(session_id);
CREATE INDEX IF NOT EXISTS castor_chat_message_user_idx ON castor_chat_message(user_id);

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

  BEGIN
    v_uuid := p_session_id::uuid;
    INSERT INTO castor_chat_session(session_id, user_id)
    VALUES (v_uuid, p_user_id)
    ON CONFLICT (session_id) DO UPDATE
      SET user_id    = COALESCE(castor_chat_session.user_id, EXCLUDED.user_id),
          updated_at = NOW();
  EXCEPTION WHEN invalid_text_representation THEN
    NULL;
  END;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION castor_chat_stamp_user(TEXT, UUID) TO authenticated;

INSERT INTO castor_schema_migrations(version)
VALUES ('003_chat') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ========================== DOWN (comentado) ==========================
-- BEGIN;
-- DROP FUNCTION IF EXISTS castor_chat_stamp_user(TEXT, UUID);
-- DROP TABLE IF EXISTS castor_chat_message;
-- DROP TABLE IF EXISTS castor_chat_session;
-- COMMIT;
