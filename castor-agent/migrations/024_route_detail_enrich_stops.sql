-- 024_route_detail_enrich_stops.sql
-- ============================================================
-- Objetivo
--   Os cards do Kanban (vendedor e admin) ficavam todos em "A fazer"
--   porque a coluna castor_route_saved.stops (jsonb) só recebe
--   outcome/next_contact_at quando o vendedor registra a visita pelo
--   popover do próprio card (castor_route_update_stop). Quando a
--   interação é registrada por outras vias (timeline, follow-ups,
--   reativação, leads, ou após reassign do admin), ela existe em
--   castor_client_interactions mas a JSONB stops fica desatualizada.
--
-- Solução
--   Sobrescrever castor_route_detail para enriquecer cada stop com a
--   ÚLTIMA interação não-cancelada do vendedor dono do roteiro para
--   aquele cliente_codigo, mesclando outcome / next_contact_at /
--   interaction_type / notes / next_action quando o próprio stop
--   ainda não tiver outcome registrado. Mantém o mesmo contrato JSON
--   de saída — só popula campos.
-- ============================================================

CREATE OR REPLACE FUNCTION castor_route_detail(
  p_user_id  UUID,
  p_route_id UUID
)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_is_admin     BOOLEAN;
  v_row          castor_route_saved%ROWTYPE;
  v_owner        JSONB;
  v_stops_out    JSONB := '[]'::jsonb;
  v_stop         JSONB;
  v_codigo       TEXT;
  v_int          RECORD;
  v_done_count   INT := 0;
  v_today        DATE := CURRENT_DATE;
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

  -- Enriquece cada parada com a última interação registrada (do dono do
  -- roteiro) para aquele cliente, quando o stop em si não tem outcome.
  -- Isso faz o classify do front (que olha s.outcome / s.next_contact_at)
  -- distribuir os cards entre A fazer / Em andamento / Travados / Fechados
  -- corretamente, mesmo após reassign do admin ou interações vindas pela
  -- timeline.
  FOR v_stop IN SELECT * FROM jsonb_array_elements(COALESCE(v_row.stops, '[]'::jsonb)) LOOP
    v_codigo := v_stop->>'cliente_codigo';

    -- Já tem outcome explícito no stop? Mantém — é a verdade da rota.
    IF v_stop ? 'outcome' AND COALESCE(v_stop->>'outcome','') <> '' THEN
      v_stops_out := v_stops_out || jsonb_build_array(v_stop);
    ELSE
      -- Busca última interação relevante para aquele cliente, do dono do
      -- roteiro. Se for admin sem interação, deixa como está (A fazer).
      SELECT i.outcome, i.interaction_type, i.notes,
             i.next_contact_at, i.next_action, i.occurred_at
        INTO v_int
        FROM castor_client_interactions i
       WHERE i.cliente_codigo = v_codigo
         AND i.vendedor_user_id = v_row.user_id
       ORDER BY i.occurred_at DESC
       LIMIT 1;

      IF FOUND AND COALESCE(v_int.outcome,'') <> '' THEN
        v_stop := v_stop
          || jsonb_build_object(
               'outcome',          v_int.outcome,
               'interaction_type', v_int.interaction_type,
               'visited_at',       v_int.occurred_at
             )
          || (CASE WHEN v_int.notes IS NOT NULL AND btrim(v_int.notes) <> ''
                    THEN jsonb_build_object('notes', v_int.notes)
                    ELSE '{}'::jsonb END)
          || (CASE WHEN v_int.next_contact_at IS NOT NULL
                    THEN jsonb_build_object('next_contact_at',
                          to_char(v_int.next_contact_at,'YYYY-MM-DD'))
                    ELSE '{}'::jsonb END)
          || (CASE WHEN v_int.next_action IS NOT NULL AND btrim(v_int.next_action) <> ''
                    THEN jsonb_build_object('next_action', v_int.next_action)
                    ELSE '{}'::jsonb END);
      END IF;
      v_stops_out := v_stops_out || jsonb_build_array(v_stop);
    END IF;

    -- conta como "fechada" (mesma regra do done_count anterior) se o stop
    -- enriquecido tem outcome terminal.
    IF (v_stop->>'outcome') IN ('visitou','convertido','nao_existe_mais','nao_interessado_permanente') THEN
      v_done_count := v_done_count + 1;
    END IF;
  END LOOP;

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
      'stops', v_stops_out,
      'stops_count', COALESCE(jsonb_array_length(v_stops_out), 0),
      'done_count', v_done_count,
      'created_at', v_row.created_at,
      'updated_at', v_row.updated_at,
      'completed_at', v_row.completed_at,
      'user_id', v_row.user_id,
      'owner', v_owner
    )
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_route_detail(UUID, UUID) TO authenticated, service_role;

INSERT INTO castor_schema_migrations(version)
VALUES ('024_route_detail_enrich_stops')
ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';
