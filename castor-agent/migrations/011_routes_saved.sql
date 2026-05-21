-- ============================================================
-- Castor migration 011 — Roteiros salvos + parser SC5 mais robusto
-- ============================================================
-- 1) Corrige `castor_parse_le` para ancorar municipio-UF DEPOIS do CEP
--    (evita matches espúrios em complementos do endereço).
-- 2) `castor_route_saved` + RPCs (list, save, update_stop).
-- 3) Ranking helper `castor_route_candidates(user_id, mode, limit)` —
--    usado pelo subflow Auto-Route Builder da IA.
-- ============================================================

BEGIN;

-- ============================================================
-- 1) Parser robusto: ancora "MUN-UF" DEPOIS do CEP (greedy lazy),
--    com fallback ao último "MUN-UF" da string.
--
--    NOTA: 010_richer_snapshot.sql cria a função com a assinatura
--    `castor_parse_le(p_text TEXT)`. Como o Postgres não deixa
--    renomear parâmetro num CREATE OR REPLACE, mantemos `p_text`.
-- ============================================================
DROP FUNCTION IF EXISTS castor_parse_le(TEXT);

CREATE OR REPLACE FUNCTION castor_parse_le(p_text TEXT)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  s        TEXT := upper(coalesce(p_text, ''));
  m        TEXT[];
  v_cep    TEXT;
  v_mun    TEXT;
  v_uf     TEXT;
  v_end    TEXT;
BEGIN
  IF btrim(s) = '' THEN
    RETURN jsonb_build_object('endereco', NULL, 'cep', NULL, 'municipio', NULL, 'uf', NULL);
  END IF;

  -- Estratégia 1 (preferida): "CEP nnnnnnnn  MUN-UF [resto]" — greedy lazy.
  -- Captura tudo entre o CEP e o "-UF" como município.
  m := regexp_match(s, 'CEP:?\s*([0-9]{5})-?([0-9]{3})\s+(.+?)-([A-Z]{2})(?:\s|$)');
  IF m IS NOT NULL THEN
    v_cep := m[1] || m[2];
    v_mun := btrim(m[3]);
    v_uf  := m[4];
  ELSE
    -- Fallback A: só CEP, sem MUN-UF detectável depois.
    m := regexp_match(s, 'CEP:?\s*([0-9]{5})-?([0-9]{3})');
    IF m IS NOT NULL THEN v_cep := m[1] || m[2]; END IF;
    -- Fallback B: último "MUN-UF" da string toda (sem CEP).
    m := regexp_match(s, '([A-ZÀ-Ú][A-ZÀ-Ú0-9 .\/]{1,60})-([A-Z]{2})(?:[^A-Z]|$)');
    IF m IS NOT NULL THEN
      v_mun := btrim(m[1]);
      v_uf  := m[2];
    END IF;
  END IF;

  -- Limpeza do município: tira dígitos finais e múltiplos espaços
  IF v_mun IS NOT NULL THEN
    v_mun := btrim(regexp_replace(v_mun, '\s+[0-9]+\s*$', '', 'g'));
    v_mun := regexp_replace(v_mun, '\s+', ' ', 'g');
    IF v_mun = '' THEN v_mun := NULL; END IF;
  END IF;

  -- Endereço = trecho antes do CEP, sem prefixo "L.E:".
  v_end := regexp_replace(s, '\s*CEP:?\s*[0-9]{5}-?[0-9]{3}.*$', '', 'i');
  v_end := regexp_replace(v_end, '^\s*L\.?E\.?:?\s*', '', 'i');
  v_end := btrim(v_end);
  IF v_end = '' THEN v_end := NULL; END IF;

  RETURN jsonb_build_object(
    'endereco',  v_end,
    'cep',       v_cep,
    'municipio', v_mun,
    'uf',        v_uf
  );
END;
$$;

GRANT EXECUTE ON FUNCTION castor_parse_le(TEXT) TO authenticated, service_role;

-- ============================================================
-- 2) Roteiros SALVOS (persistentes, com paradas e outcomes inline)
-- ============================================================
CREATE TABLE IF NOT EXISTS castor_route_saved (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID,                                                  -- sem ON DELETE CASCADE
  name            TEXT NOT NULL,
  source          TEXT NOT NULL CHECK (source IN ('ai_auto','manual','mixed','reactivation','prospect')),
  status          TEXT NOT NULL DEFAULT 'planejado' CHECK (status IN ('planejado','em_andamento','concluido','cancelado')),
  stops           JSONB NOT NULL,    -- [{seq,cliente_codigo,name,lat,lng,leg_km,cum_km,outcome?,visited_at?,notes?}]
  total_km        NUMERIC(10,2),
  origin_lat      DOUBLE PRECISION,
  origin_lng      DOUBLE PRECISION,
  ai_rationale    TEXT,
  maps_url        TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS castor_route_saved_user_idx    ON castor_route_saved(user_id);
CREATE INDEX IF NOT EXISTS castor_route_saved_status_idx  ON castor_route_saved(status);
CREATE INDEX IF NOT EXISTS castor_route_saved_created_idx ON castor_route_saved(created_at DESC);

CREATE OR REPLACE FUNCTION castor_route_saved_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := NOW(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS castor_route_saved_touch_trg ON castor_route_saved;
CREATE TRIGGER castor_route_saved_touch_trg BEFORE UPDATE ON castor_route_saved
FOR EACH ROW EXECUTE FUNCTION castor_route_saved_touch();

-- ============================================================
-- 2a) Salvar uma rota nova
-- ============================================================
CREATE OR REPLACE FUNCTION castor_route_save(
  p_user_id      UUID,
  p_name         TEXT,
  p_source       TEXT,
  p_stops        JSONB,
  p_total_km     NUMERIC,
  p_origin_lat   DOUBLE PRECISION,
  p_origin_lng   DOUBLE PRECISION,
  p_ai_rationale TEXT,
  p_maps_url     TEXT
) RETURNS UUID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO castor_route_saved(user_id, name, source, stops, total_km, origin_lat, origin_lng, ai_rationale, maps_url)
  VALUES (p_user_id, COALESCE(NULLIF(btrim(p_name),''), 'Roteiro '||to_char(NOW(),'DD/MM HH24:MI')),
          COALESCE(p_source,'manual'), COALESCE(p_stops,'[]'::jsonb), p_total_km,
          p_origin_lat, p_origin_lng, p_ai_rationale, p_maps_url)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_save(UUID,TEXT,TEXT,JSONB,NUMERIC,DOUBLE PRECISION,DOUBLE PRECISION,TEXT,TEXT) TO authenticated, service_role;

-- ============================================================
-- 2b) Listar rotas do usuário (admin vê todas)
-- ============================================================
CREATE OR REPLACE FUNCTION castor_route_list(
  p_user_id    UUID,
  p_only_open  BOOLEAN DEFAULT FALSE,
  p_limit      INT     DEFAULT 50
)
RETURNS TABLE(
  id UUID, name TEXT, source TEXT, status TEXT,
  total_km NUMERIC, stops_count INT, done_count INT,
  ai_rationale TEXT, maps_url TEXT,
  created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, completed_at TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE v_is_admin BOOLEAN;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  RETURN QUERY
  SELECT r.id, r.name, r.source, r.status,
         r.total_km,
         COALESCE(jsonb_array_length(r.stops),0)::INT AS stops_count,
         (SELECT COUNT(*)::INT FROM jsonb_array_elements(r.stops) s
            WHERE (s->>'outcome') IS NOT NULL) AS done_count,
         r.ai_rationale, r.maps_url,
         r.created_at, r.updated_at, r.completed_at
    FROM castor_route_saved r
   WHERE (v_is_admin OR r.user_id = p_user_id)
     AND (NOT p_only_open OR r.status IN ('planejado','em_andamento'))
   ORDER BY r.created_at DESC
   LIMIT GREATEST(1, LEAST(COALESCE(p_limit,50), 200));
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_list(UUID,BOOLEAN,INT) TO authenticated, service_role;

-- ============================================================
-- 2c) Atualizar uma parada (registra visita e replica para feedback)
-- ============================================================
CREATE OR REPLACE FUNCTION castor_route_update_stop(
  p_user_id        UUID,
  p_route_id       UUID,
  p_cliente_codigo TEXT,
  p_outcome        TEXT,      -- 'visitou' | 'sem_contato' | 'convertido' | 'voltar_depois' | 'negativo' | NULL para limpar
  p_notes          TEXT,
  p_custom_days    INT
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_row     castor_route_saved%ROWTYPE;
  v_stops   JSONB;
  v_new     JSONB := '[]'::JSONB;
  v_elem    JSONB;
  v_open    INT := 0;
  v_done    INT := 0;
  v_total   INT := 0;
  v_is_admin BOOLEAN;
  v_feedback_outcome TEXT;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  SELECT * INTO v_row FROM castor_route_saved WHERE id = p_route_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','route_not_found');
  END IF;
  IF NOT v_is_admin AND v_row.user_id <> p_user_id THEN
    RETURN jsonb_build_object('ok',false,'error','forbidden');
  END IF;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(v_row.stops) LOOP
    v_total := v_total + 1;
    IF (v_elem->>'cliente_codigo') = p_cliente_codigo THEN
      IF p_outcome IS NULL THEN
        v_elem := v_elem - 'outcome' - 'visited_at' - 'notes';
      ELSE
        v_elem := v_elem
          || jsonb_build_object('outcome', p_outcome)
          || jsonb_build_object('visited_at', NOW())
          || (CASE WHEN p_notes IS NOT NULL AND p_notes <> ''
                    THEN jsonb_build_object('notes', p_notes)
                    ELSE '{}'::jsonb END);
      END IF;
    END IF;
    IF (v_elem->>'outcome') IS NOT NULL THEN v_done := v_done + 1; END IF;
    v_new := v_new || jsonb_build_array(v_elem);
  END LOOP;

  v_open := v_total - v_done;

  UPDATE castor_route_saved SET
    stops        = v_new,
    status       = CASE
                     WHEN v_done = 0          THEN 'planejado'
                     WHEN v_open = 0          THEN 'concluido'
                     ELSE 'em_andamento'
                   END,
    completed_at = CASE WHEN v_open = 0 THEN NOW() ELSE NULL END
   WHERE id = p_route_id;

  -- Replica no histórico de feedback (drives a próxima visita) para outcomes conhecidos.
  v_feedback_outcome := CASE p_outcome
    WHEN 'convertido'     THEN 'convertido'
    WHEN 'voltar_depois'  THEN 'voltar_depois'
    WHEN 'negativo'       THEN 'negativo'
    WHEN 'sem_contato'    THEN 'voltar_depois'
    ELSE NULL
  END;
  IF v_feedback_outcome IS NOT NULL THEN
    PERFORM castor_register_visit_feedback(
      p_cliente_codigo, v_feedback_outcome,
      p_custom_days, p_notes, p_route_id::TEXT || ':' || p_cliente_codigo
    );
  END IF;

  RETURN jsonb_build_object('ok',true,'route_id',p_route_id,'done',v_done,'total',v_total);
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_update_stop(UUID,UUID,TEXT,TEXT,TEXT,INT) TO authenticated, service_role;

-- ============================================================
-- 3) Helper de ranking para o subflow Auto-Route Builder
--    Devolve top N candidatos com geocode disponível, dentro do escopo
--    do vendedor, ordenados por urgencia_score.
-- ============================================================
CREATE OR REPLACE FUNCTION castor_route_candidates(
  p_user_id   UUID,
  p_mode      TEXT,         -- 'reactivation' | 'mixed' | 'prospect_skip'
  p_uf        TEXT,         -- filtro opcional (NULL = nenhum)
  p_cidade    TEXT,         -- filtro opcional
  p_limit     INT
)
RETURNS TABLE(
  cliente_codigo TEXT, a1_nome TEXT, a1_vend TEXT,
  a1_mun TEXT, a1_est TEXT, a1_end TEXT, a1_cep TEXT,
  status_real TEXT, urgencia_score INT,
  faturamento_alltime NUMERIC, ultimo_pedido DATE, dias_sem_pedido INT,
  porte_efetivo TEXT, lat DOUBLE PRECISION, lng DOUBLE PRECISION
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_role TEXT;
  v_vend TEXT;
  v_est  TEXT[];
  v_cid  TEXT[];
BEGIN
  SELECT s.role, s.vendor_code, s.estados, s.cidades
    INTO v_role, v_vend, v_est, v_cid
  FROM castor_user_scope(p_user_id) s;
  v_role := COALESCE(v_role,'vendedor');

  RETURN QUERY
  SELECT
    m.cliente_codigo, m.a1_nome, m.a1_vend,
    m.a1_mun, m.a1_est, m.a1_end, m.a1_cep,
    m.status_real, m.urgencia_score,
    m.faturamento_alltime, m.ultimo_pedido, m.dias_sem_pedido,
    m.porte_efetivo, g.lat, g.lng
  FROM castor_client_metrics_v2 m
  LEFT JOIN castor_geocode_cache g
    ON g.scope = 'municipio'
   AND g.query_key = upper(coalesce(m.a1_mun,'')) || '|' || upper(coalesce(m.a1_est,''))
   AND g.ok
  WHERE g.lat IS NOT NULL AND g.lng IS NOT NULL
    AND (v_role = 'admin' OR (
          (v_vend IS NULL OR m.a1_vend = v_vend)
          AND (v_est IS NULL OR upper(coalesce(m.a1_est,'')) = ANY(v_est))
          AND (v_cid IS NULL OR upper(coalesce(m.a1_mun,'')) = ANY(v_cid))
        ))
    AND (p_uf     IS NULL OR upper(coalesce(m.a1_est,'')) = upper(p_uf))
    AND (p_cidade IS NULL OR upper(coalesce(m.a1_mun,'')) = upper(p_cidade))
    AND CASE p_mode
          WHEN 'reactivation' THEN m.status_real IN ('EM_RISCO','REATIVAR','INATIVO','DORMENTE')
          WHEN 'prospect_skip' THEN m.status_real IN ('EM_RISCO','REATIVAR','INATIVO','DORMENTE')
          ELSE TRUE
        END
    AND m.pedidos_alltime >= 1
  ORDER BY m.urgencia_score DESC NULLS LAST, m.faturamento_alltime DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit,12), 30));
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_candidates(UUID,TEXT,TEXT,TEXT,INT) TO authenticated, service_role;

-- ============================================================
-- 4) Re-aplicar parser (caso já tenha SC5 ingerido) — opcional;
--    o Source-Manager chama isso a cada ingest.
-- ============================================================
SELECT castor_refresh_sc5_address();

INSERT INTO castor_schema_migrations(version) VALUES ('011_routes_saved') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';
