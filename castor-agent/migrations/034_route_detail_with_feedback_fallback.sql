-- file: 034_route_detail_with_feedback_fallback.sql
-- tier: A
-- purpose:
--   Bug persistente: vendedor responde um card no kanban, o feedback
--   aparece na timeline ("Histórico de visitas") mas o card continua em
--   "A fazer" com data de retorno antiga.
--
--   Causa: dependendo de POR ONDE o vendedor respondeu, a fonte da
--   verdade pode ser diferente:
--     • Modal "Nova interação" (PANEL_INTERACTION_ADD_URL) →
--         escreve em castor_client_interactions (e espelha em
--         castor_visita_feedback).
--     • Popover do próprio card / castor_route_update_stop →
--         atualiza o jsonb stops + chama castor_client_interaction_add
--         (que também escreve em ambas as tabelas).
--     • Fluxo legado (chat-agent / register_visit_feedback) →
--         escreve APENAS em castor_visita_feedback.
--
--   A 032 enriquecia stops apenas a partir de castor_client_interactions
--   — perdendo o caso 3 (legado). Esta migração adiciona fallback para
--   castor_visita_feedback e sempre escolhe o evento MAIS RECENTE entre
--   as duas fontes.
--
-- depends: 015 (interactions), 024/032 (route_detail enrichment)
-- reversible: yes
-- IDEMPOTENTE.

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
  v_done_count   INT := 0;

  v_outcome      TEXT;
  v_itype        TEXT;
  v_notes        TEXT;
  v_next_at      DATE;
  v_next_action  TEXT;
  v_occurred_at  TIMESTAMPTZ;

  v_stop_visited TIMESTAMPTZ;
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

  FOR v_stop IN SELECT * FROM jsonb_array_elements(COALESCE(v_row.stops, '[]'::jsonb)) LOOP
    v_codigo := v_stop->>'cliente_codigo';

    -- Pega o evento MAIS RECENTE entre castor_client_interactions e
    -- castor_visita_feedback, do dono do roteiro, para aquele cliente.
    -- Fontes diferentes (modal de interação, popover, chat legado)
    -- escrevem em tabelas diferentes; comparamos por timestamp.
    SELECT outcome, interaction_type, notes, next_contact_at, next_action, occurred_at
      INTO v_outcome, v_itype, v_notes, v_next_at, v_next_action, v_occurred_at
      FROM (
        SELECT i.outcome, i.interaction_type, i.notes,
               i.next_contact_at, i.next_action, i.occurred_at
          FROM castor_client_interactions i
         WHERE i.cliente_codigo = v_codigo
           AND i.vendedor_user_id = v_row.user_id
        UNION ALL
        SELECT f.outcome,
               'visita_presencial'::TEXT      AS interaction_type,
               f.notes,
               f.next_contact_at,
               NULL::TEXT                     AS next_action,
               f.visited_at                   AS occurred_at
          FROM castor_visita_feedback f
         WHERE f.cliente_codigo = v_codigo
           AND f.vendedor_user_id = v_row.user_id
      ) src
     WHERE COALESCE(outcome,'') <> ''
     ORDER BY occurred_at DESC NULLS LAST
     LIMIT 1;

    IF v_outcome IS NOT NULL AND v_outcome <> '' THEN
      v_stop_visited := NULLIF(v_stop->>'visited_at','')::TIMESTAMPTZ;
      -- Sobrepõe quando o stop não tem visited_at OU o evento é mais
      -- recente. Empate (>=) também sobrepõe — caso típico de duas
      -- respostas no mesmo segundo (mirror duplicado).
      IF v_stop_visited IS NULL OR v_occurred_at >= v_stop_visited THEN
        v_stop := v_stop
          || jsonb_build_object(
               'outcome',          v_outcome,
               'interaction_type', v_itype,
               'visited_at',       v_occurred_at
             )
          || jsonb_build_object(
               'next_contact_at',
               CASE WHEN v_next_at IS NOT NULL
                    THEN to_char(v_next_at,'YYYY-MM-DD')
                    ELSE NULL END
             )
          || (CASE WHEN v_notes IS NOT NULL AND btrim(v_notes) <> ''
                    THEN jsonb_build_object('notes', v_notes)
                    ELSE '{}'::jsonb END)
          || (CASE WHEN v_next_action IS NOT NULL AND btrim(v_next_action) <> ''
                    THEN jsonb_build_object('next_action', v_next_action)
                    ELSE '{}'::jsonb END);
      END IF;
    END IF;

    v_stops_out := v_stops_out || jsonb_build_array(v_stop);

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
VALUES ('034_route_detail_with_feedback_fallback') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';
