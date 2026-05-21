-- ============================================================
-- 022 — UM ÚNICO roteiro EM ABERTO por vendedor
-- ------------------------------------------------------------
-- Regra de negócio (confirmada): cada vendedor pode ter no máximo 1 roteiro
-- com status IN ('planejado','em_andamento'). Roteiros concluídos/cancelados
-- viram histórico imutável (quantos quiser).
--
-- O fluxo já estava parcialmente OK via `castor_route_save_unified`
-- (016_route_unified.sql) — que faz APPEND na rota aberta existente. Mas
-- nada impedia que rotas legadas / chamadas diretas a `castor_route_save`
-- criassem duplicatas. Esta migração:
--   1) CONSOLIDA duplicatas pré-existentes: para cada vendedor, mantém a
--      rota aberta mais recente e mescla as paradas das demais nela.
--      As "extras" viram 'cancelado' (preserva histórico — não apaga).
--   2) Cria índice ÚNICO PARCIAL impedindo > 1 rota aberta por user_id.
--   3) Revoga a RPC legada `castor_route_save` (substituída pela unificada).
--
-- Idempotente. Não usa CASCADE. Não toca em auth.users.
-- ============================================================

BEGIN;

-- ============================================================
-- 1) Consolida duplicatas pré-existentes
--    Para cada vendedor com > 1 rota aberta, mantém a mais recente e
--    move as paradas das antigas para ela (dedupe por cliente_codigo),
--    depois marca as antigas como 'cancelado'.
-- ============================================================
DO $$
DECLARE
  v_user UUID;
  v_keep UUID;
  v_old  RECORD;
  v_keep_stops JSONB;
  v_known TEXT[];
  v_max_seq INT;
  v_elem JSONB;
  v_keep_total NUMERIC;
  v_keep_origin_lat DOUBLE PRECISION;
  v_keep_origin_lng DOUBLE PRECISION;
BEGIN
  FOR v_user IN
    SELECT user_id
      FROM castor_route_saved
     WHERE status IN ('planejado','em_andamento')
       AND user_id IS NOT NULL
     GROUP BY user_id
    HAVING COUNT(*) > 1
  LOOP
    -- mantém a rota aberta mais recente
    SELECT id INTO v_keep
      FROM castor_route_saved
     WHERE user_id = v_user
       AND status IN ('planejado','em_andamento')
     ORDER BY created_at DESC
     LIMIT 1;

    SELECT stops, COALESCE(total_km,0), origin_lat, origin_lng
      INTO v_keep_stops, v_keep_total, v_keep_origin_lat, v_keep_origin_lng
      FROM castor_route_saved WHERE id = v_keep;

    SELECT COALESCE(array_agg(s->>'cliente_codigo'), ARRAY[]::TEXT[])
      INTO v_known
      FROM jsonb_array_elements(COALESCE(v_keep_stops,'[]'::jsonb)) s;

    SELECT COALESCE(MAX((s->>'seq')::INT), 0)
      INTO v_max_seq
      FROM jsonb_array_elements(COALESCE(v_keep_stops,'[]'::jsonb)) s;

    FOR v_old IN
      SELECT id, stops, COALESCE(total_km,0) AS total_km, origin_lat, origin_lng
        FROM castor_route_saved
       WHERE user_id = v_user
         AND status IN ('planejado','em_andamento')
         AND id <> v_keep
       ORDER BY created_at ASC
    LOOP
      FOR v_elem IN SELECT * FROM jsonb_array_elements(COALESCE(v_old.stops,'[]'::jsonb)) LOOP
        IF (v_elem->>'cliente_codigo') IS NULL THEN CONTINUE; END IF;
        IF (v_elem->>'cliente_codigo') = ANY(v_known) THEN CONTINUE; END IF;
        v_max_seq := v_max_seq + 1;
        v_keep_stops := v_keep_stops || jsonb_build_array(
          jsonb_set(v_elem, '{seq}', to_jsonb(v_max_seq), TRUE)
        );
        v_known := array_append(v_known, v_elem->>'cliente_codigo');
      END LOOP;
      v_keep_total := v_keep_total + v_old.total_km;
      IF v_keep_origin_lat IS NULL THEN v_keep_origin_lat := v_old.origin_lat; END IF;
      IF v_keep_origin_lng IS NULL THEN v_keep_origin_lng := v_old.origin_lng; END IF;

      -- marca a rota antiga como cancelada (preserva histórico)
      UPDATE castor_route_saved
         SET status = 'cancelado',
             updated_at = NOW(),
             ai_rationale = COALESCE(ai_rationale,'') ||
               E'\n---\n[022] Mesclada na rota aberta '||v_keep::text||' em '||NOW()::text
       WHERE id = v_old.id;
    END LOOP;

    -- aplica merge na rota mantida
    UPDATE castor_route_saved
       SET stops      = v_keep_stops,
           total_km   = v_keep_total,
           origin_lat = v_keep_origin_lat,
           origin_lng = v_keep_origin_lng,
           maps_url   = castor_route_build_maps_url(v_keep_origin_lat, v_keep_origin_lng, v_keep_stops),
           updated_at = NOW()
     WHERE id = v_keep;
  END LOOP;
END $$;

-- ============================================================
-- 2) Índice ÚNICO PARCIAL: no máximo 1 rota aberta por usuário
-- ============================================================
CREATE UNIQUE INDEX IF NOT EXISTS castor_route_saved_one_open_per_user_uq
  ON castor_route_saved(user_id)
  WHERE status IN ('planejado','em_andamento');

-- ============================================================
-- 3) Aposenta a RPC legada `castor_route_save` (a unificada é a oficial).
--    Mantém a função (alguém pode ter dependência), mas a redireciona
--    para a unificada — assim qualquer chamada respeitará a regra.
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
DECLARE
  v_res JSONB;
BEGIN
  v_res := castor_route_save_unified(
    p_user_id, p_name, p_source, p_stops, p_total_km,
    p_origin_lat, p_origin_lng, p_ai_rationale, p_maps_url
  );
  RETURN (v_res->>'route_id')::UUID;
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_save(UUID,TEXT,TEXT,JSONB,NUMERIC,DOUBLE PRECISION,DOUBLE PRECISION,TEXT,TEXT) TO authenticated, service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';
