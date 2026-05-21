-- ============================================================
-- 017 — done_count = somente outcomes TERMINAIS (visitou/convertido)
-- ------------------------------------------------------------
-- Antes: "outcome IS NOT NULL" contava aguardando_resposta, voltar_depois,
-- pedido_em_negociacao etc. como "concluído". Agora alinha com o kanban
-- (coluna "Concluídos" = visitou + convertido). Outcomes terminais negativos
-- (nao_existe_mais / nao_interessado_permanente) também contam como done.
-- ============================================================

-- Conjunto canônico de outcomes que encerram a tarefa.
-- IMUTÁVEL: usado dentro das duas funções abaixo.
-- ------------------------------------------------------------

-- Recria castor_route_list (versão admin) — assinatura idêntica à 013.
CREATE OR REPLACE FUNCTION castor_route_list(
  p_user_id    UUID,
  p_only_open  BOOLEAN DEFAULT FALSE,
  p_limit      INT     DEFAULT 50
)
RETURNS TABLE(
  id UUID, name TEXT, source TEXT, status TEXT,
  total_km NUMERIC, stops_count INT, done_count INT,
  ai_rationale TEXT, maps_url TEXT,
  created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, completed_at TIMESTAMPTZ,
  user_id UUID, user_name TEXT
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
            WHERE (s->>'outcome') IN ('visitou','convertido','nao_existe_mais','nao_interessado_permanente')
         ) AS done_count,
         r.ai_rationale, r.maps_url,
         r.created_at, r.updated_at, r.completed_at,
         r.user_id,
         (SELECT u.raw_user_meta_data->>'full_name' FROM auth.users u WHERE u.id = r.user_id) AS user_name
    FROM castor_route_saved r
   WHERE (v_is_admin OR r.user_id = p_user_id)
     AND (NOT p_only_open OR r.status IN ('planejado','em_andamento'))
   ORDER BY r.created_at DESC
   LIMIT GREATEST(1, LEAST(COALESCE(p_limit,50), 200));
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_list(UUID,BOOLEAN,INT) TO authenticated, service_role;

-- Recria castor_route_detail — mesmo objeto, ajusta done_count.
CREATE OR REPLACE FUNCTION castor_route_detail(
  p_user_id  UUID,
  p_route_id UUID
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_is_admin BOOLEAN;
  v_row      castor_route_saved%ROWTYPE;
  v_owner    JSONB;
BEGIN
  SELECT COALESCE((u.raw_user_meta_data->>'role'),'vendedor')='admin'
    INTO v_is_admin FROM auth.users u WHERE u.id = p_user_id;

  SELECT * INTO v_row FROM castor_route_saved WHERE id = p_route_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'route_not_found');
  END IF;

  IF NOT v_is_admin AND v_row.user_id <> p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  SELECT to_jsonb(u.*) INTO v_owner
    FROM (SELECT id, email, raw_user_meta_data->>'full_name' AS full_name
            FROM auth.users WHERE id = v_row.user_id) u;

  RETURN jsonb_build_object(
    'ok', true,
    'route', jsonb_build_object(
      'id', v_row.id,
      'name', v_row.name,
      'source', v_row.source,
      'status', v_row.status,
      'total_km', v_row.total_km,
      'origin_lat', v_row.origin_lat,
      'origin_lng', v_row.origin_lng,
      'ai_rationale', v_row.ai_rationale,
      'maps_url', v_row.maps_url,
      'stops', v_row.stops,
      'stops_count', COALESCE(jsonb_array_length(v_row.stops), 0),
      'done_count', (SELECT COUNT(*)::INT FROM jsonb_array_elements(v_row.stops) s
                       WHERE (s->>'outcome') IN ('visitou','convertido','nao_existe_mais','nao_interessado_permanente')),
      'created_at', v_row.created_at,
      'updated_at', v_row.updated_at,
      'completed_at', v_row.completed_at,
      'user_id', v_row.user_id,
      'owner', v_owner
    )
  );
END; $$;
GRANT EXECUTE ON FUNCTION castor_route_detail(UUID, UUID) TO authenticated, service_role;

INSERT INTO castor_schema_migrations(version) VALUES ('017_done_count_fix') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';
