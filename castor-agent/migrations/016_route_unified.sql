-- ============================================================
-- 016 — Roteiro UNIFICADO por vendedor
-- ------------------------------------------------------------
-- Objetivo: parar de criar uma rota nova a cada "Gerar".
-- Regra:
--   * Se o vendedor já tem uma rota com status IN ('planejado','em_andamento'),
--     as novas paradas são APPENDADAS nela (dedupe por cliente_codigo).
--   * Senão, cria uma rota nova como hoje.
--   * `total_km` é recalculado pela soma das `leg_km` informadas + as antigas;
--     `maps_url` é regenerado a partir do estado final.
-- Idempotente. Não toca tabelas existentes — apenas adiciona a função e o
-- helper de re-render do Maps URL.
-- ============================================================

-- Helper: regera maps_url a partir dos stops com lat/lng válidos (≤ 25 waypoints).
CREATE OR REPLACE FUNCTION castor_route_build_maps_url(
  p_origin_lat DOUBLE PRECISION,
  p_origin_lng DOUBLE PRECISION,
  p_stops      JSONB
) RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_url TEXT;
  v_pts TEXT := '';
  v_count INT := 0;
  v_elem JSONB;
  v_lat DOUBLE PRECISION;
  v_lng DOUBLE PRECISION;
BEGIN
  IF p_origin_lat IS NULL OR p_origin_lng IS NULL OR p_stops IS NULL OR jsonb_array_length(p_stops) = 0 THEN
    RETURN NULL;
  END IF;
  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_stops) LOOP
    v_lat := NULLIF(v_elem->>'lat','')::DOUBLE PRECISION;
    v_lng := NULLIF(v_elem->>'lng','')::DOUBLE PRECISION;
    IF v_lat IS NULL OR v_lng IS NULL THEN CONTINUE; END IF;
    v_count := v_count + 1;
    IF v_count > 23 THEN EXIT; END IF; -- Maps limita waypoints
    v_pts := v_pts || '/' || v_lat::TEXT || ',' || v_lng::TEXT;
  END LOOP;
  IF v_count = 0 THEN RETURN NULL; END IF;
  v_url := 'https://www.google.com/maps/dir/' ||
           p_origin_lat::TEXT || ',' || p_origin_lng::TEXT ||
           v_pts ||
           '/' || p_origin_lat::TEXT || ',' || p_origin_lng::TEXT;
  RETURN v_url;
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_build_maps_url(DOUBLE PRECISION,DOUBLE PRECISION,JSONB) TO authenticated, service_role;


-- Append OU cria — devolve route_id + flag "appended"
CREATE OR REPLACE FUNCTION castor_route_save_unified(
  p_user_id      UUID,
  p_name         TEXT,
  p_source       TEXT,
  p_stops        JSONB,
  p_total_km     NUMERIC,
  p_origin_lat   DOUBLE PRECISION,
  p_origin_lng   DOUBLE PRECISION,
  p_ai_rationale TEXT,
  p_maps_url     TEXT
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  v_existing castor_route_saved%ROWTYPE;
  v_id       UUID;
  v_merged   JSONB;
  v_known    TEXT[];
  v_max_seq  INT := 0;
  v_elem     JSONB;
  v_origin_lat DOUBLE PRECISION;
  v_origin_lng DOUBLE PRECISION;
  v_total_km NUMERIC;
  v_appended BOOLEAN := FALSE;
  v_count_new INT := 0;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'user_id obrigatorio'; END IF;
  IF p_stops IS NULL OR jsonb_array_length(p_stops) = 0 THEN
    RAISE EXCEPTION 'stops vazio';
  END IF;

  -- procura rota ABERTA do vendedor (a mais recente)
  SELECT * INTO v_existing
    FROM castor_route_saved
   WHERE user_id = p_user_id
     AND status IN ('planejado','em_andamento')
   ORDER BY created_at DESC
   LIMIT 1;

  IF v_existing.id IS NULL THEN
    -- cria normalmente, como castor_route_save fazia
    INSERT INTO castor_route_saved(
      user_id, name, source, stops, total_km,
      origin_lat, origin_lng, ai_rationale, maps_url
    )
    VALUES (
      p_user_id,
      COALESCE(NULLIF(btrim(p_name),''), 'Roteiro do dia '||to_char(NOW(),'DD/MM')),
      COALESCE(p_source,'manual'),
      COALESCE(p_stops,'[]'::jsonb),
      p_total_km,
      p_origin_lat, p_origin_lng, p_ai_rationale, p_maps_url
    )
    RETURNING id INTO v_id;
    RETURN jsonb_build_object(
      'route_id', v_id,
      'appended', FALSE,
      'added_count', jsonb_array_length(COALESCE(p_stops,'[]'::jsonb))
    );
  END IF;

  -- APPEND: dedupe por cliente_codigo, renumera seq, recalcula maps_url
  v_appended := TRUE;
  v_id := v_existing.id;

  -- coleta cliente_codigo já presente
  SELECT COALESCE(array_agg(s->>'cliente_codigo'), ARRAY[]::TEXT[])
    INTO v_known
    FROM jsonb_array_elements(COALESCE(v_existing.stops,'[]'::jsonb)) s;

  -- pega o seq máximo atual
  SELECT COALESCE(MAX((s->>'seq')::INT), 0)
    INTO v_max_seq
    FROM jsonb_array_elements(COALESCE(v_existing.stops,'[]'::jsonb)) s;

  v_merged := COALESCE(v_existing.stops,'[]'::jsonb);

  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_stops) LOOP
    IF (v_elem->>'cliente_codigo') IS NULL THEN CONTINUE; END IF;
    IF (v_elem->>'cliente_codigo') = ANY(v_known) THEN CONTINUE; END IF; -- dedupe
    v_max_seq := v_max_seq + 1;
    v_count_new := v_count_new + 1;
    v_merged := v_merged || jsonb_build_array(
      jsonb_set(v_elem, '{seq}', to_jsonb(v_max_seq), TRUE)
    );
    v_known := array_append(v_known, v_elem->>'cliente_codigo');
  END LOOP;

  -- origem: mantém a existente; total_km = existente + entrada (sem otimizar globalmente)
  v_origin_lat := COALESCE(v_existing.origin_lat, p_origin_lat);
  v_origin_lng := COALESCE(v_existing.origin_lng, p_origin_lng);
  v_total_km   := COALESCE(v_existing.total_km,0) + COALESCE(p_total_km,0);

  UPDATE castor_route_saved
     SET stops      = v_merged,
         total_km   = v_total_km,
         origin_lat = v_origin_lat,
         origin_lng = v_origin_lng,
         maps_url   = castor_route_build_maps_url(v_origin_lat, v_origin_lng, v_merged),
         ai_rationale = CASE
            WHEN p_ai_rationale IS NULL OR btrim(p_ai_rationale) = '' THEN v_existing.ai_rationale
            WHEN v_existing.ai_rationale IS NULL THEN p_ai_rationale
            ELSE v_existing.ai_rationale || E'\n---\n' || p_ai_rationale
         END,
         source     = CASE
            WHEN v_existing.source = COALESCE(p_source,'manual') THEN v_existing.source
            ELSE 'mixed'
         END,
         status     = CASE WHEN v_existing.status = 'concluido' THEN 'planejado' ELSE v_existing.status END,
         updated_at = NOW()
   WHERE id = v_existing.id;

  RETURN jsonb_build_object(
    'route_id', v_id,
    'appended', TRUE,
    'added_count', v_count_new,
    'total_stops', jsonb_array_length(v_merged)
  );
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_save_unified(UUID,TEXT,TEXT,JSONB,NUMERIC,DOUBLE PRECISION,DOUBLE PRECISION,TEXT,TEXT) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
