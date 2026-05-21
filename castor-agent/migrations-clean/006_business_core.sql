-- file: 006_business_core.sql
-- tier: A
-- purpose: Feedback de visita (castor_visita_feedback) + log de rotas geradas + helper haversine.
-- depends: 001, 004
-- IDEMPOTENTE.

BEGIN;

CREATE TABLE IF NOT EXISTS castor_visita_feedback (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_codigo    TEXT NOT NULL,
  vendedor_user_id  UUID,
  vendedor_codigo   TEXT,
  visited_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  outcome           TEXT NOT NULL CHECK (outcome IN (
    'visitou','sem_contato','convertido','voltar_depois','negativo',
    'aguardando_resposta','pedido_em_negociacao',
    'nao_existe_mais','nao_interessado_permanente'
  )),
  custom_days       INT,
  next_contact_at   DATE,
  notes             TEXT,
  idempotency_key   TEXT UNIQUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS castor_visita_feedback_cli_idx    ON castor_visita_feedback(cliente_codigo);
CREATE INDEX IF NOT EXISTS castor_visita_feedback_vendor_idx ON castor_visita_feedback(vendedor_user_id);
CREATE INDEX IF NOT EXISTS castor_visita_feedback_next_idx   ON castor_visita_feedback(next_contact_at);

CREATE OR REPLACE FUNCTION castor_register_visit_feedback(
  p_cliente_codigo   TEXT,
  p_outcome          TEXT,
  p_custom_days      INT  DEFAULT NULL,
  p_notes            TEXT DEFAULT NULL,
  p_idempotency_key  TEXT DEFAULT NULL
)
RETURNS castor_visita_feedback
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_codigo   TEXT;
  v_days     INT;
  v_next     DATE;
  v_existing castor_visita_feedback;
  v_row      castor_visita_feedback;
  v_allowed  TEXT[] := ARRAY[
    'visitou','sem_contato','convertido','voltar_depois','negativo',
    'aguardando_resposta','pedido_em_negociacao',
    'nao_existe_mais','nao_interessado_permanente'
  ];
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Não autenticado.' USING ERRCODE = '42501';
  END IF;
  IF NOT (p_outcome = ANY(v_allowed)) THEN
    RAISE EXCEPTION 'Outcome inválido: %', p_outcome USING ERRCODE = '22023';
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    SELECT * INTO v_existing FROM castor_visita_feedback WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
      RETURN v_existing;
    END IF;
  END IF;

  SELECT codigo INTO v_codigo FROM castor_vendor_user WHERE user_id = v_user_id;

  IF p_outcome IN ('convertido','nao_existe_mais','nao_interessado_permanente') THEN
    v_next := NULL;
  ELSE
    v_days := COALESCE(p_custom_days, 20);
    IF v_days < 1 OR v_days > 365 THEN
      RAISE EXCEPTION 'custom_days fora do intervalo (1-365).' USING ERRCODE = '22023';
    END IF;
    v_next := (NOW() + (v_days || ' days')::INTERVAL)::DATE;
  END IF;

  INSERT INTO castor_visita_feedback(
    cliente_codigo, vendedor_user_id, vendedor_codigo, visited_at,
    outcome, custom_days, next_contact_at, notes, idempotency_key
  )
  VALUES (
    p_cliente_codigo, v_user_id, v_codigo, NOW(),
    p_outcome, p_custom_days, v_next, p_notes, p_idempotency_key
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

CREATE TABLE IF NOT EXISTS castor_route_log (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendedor_user_id UUID,
  generated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  uf               TEXT,
  municipio        TEXT,
  client_codes     TEXT[] NOT NULL,
  source           TEXT NOT NULL CHECK (source IN ('reactivation','prospect','mixed')),
  total_km         NUMERIC(10,2)
);
CREATE INDEX IF NOT EXISTS castor_route_log_user_idx ON castor_route_log(vendedor_user_id);
CREATE INDEX IF NOT EXISTS castor_route_log_at_idx   ON castor_route_log(generated_at);

CREATE OR REPLACE FUNCTION castor_haversine_km(lat1 FLOAT, lng1 FLOAT, lat2 FLOAT, lng2 FLOAT)
RETURNS FLOAT
LANGUAGE sql IMMUTABLE AS $$
  SELECT 6371.0 * 2 * ASIN(SQRT(
    POWER(SIN(RADIANS((lat2 - lat1) / 2)), 2)
    + COS(RADIANS(lat1)) * COS(RADIANS(lat2)) *
      POWER(SIN(RADIANS((lng2 - lng1) / 2)), 2)
  ));
$$;

GRANT EXECUTE ON FUNCTION castor_register_visit_feedback(TEXT, TEXT, INT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION castor_haversine_km(FLOAT,FLOAT,FLOAT,FLOAT) TO authenticated;

INSERT INTO castor_schema_migrations(version)
VALUES ('006_business_core') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ========================== DOWN (comentado) ==========================
-- BEGIN;
-- DROP FUNCTION IF EXISTS castor_haversine_km(FLOAT, FLOAT, FLOAT, FLOAT);
-- DROP FUNCTION IF EXISTS castor_register_visit_feedback(TEXT, TEXT, INT, TEXT, TEXT);
-- DROP TABLE IF EXISTS castor_route_log;
-- DROP TABLE IF EXISTS castor_visita_feedback;
-- COMMIT;
