-- file: 032_route_detail_latest_interaction.sql
-- tier: A
-- purpose:
--   Bug: vendedor responde um card no kanban "Meu Roteiro", a interaction
--   é gravada em castor_client_interactions, mas o card NÃO troca de
--   coluna no reload.
--
--   Causa: a 024 enriquecia cada stop com a última interaction APENAS
--   quando o stop ainda não tinha outcome. Se o vendedor já tinha
--   respondido o card uma vez (ou se a stop foi criada com outcome
--   pré-preenchido pelo `castor_route_update_stop`), a partir daí o
--   classify do front ficava preso no outcome antigo.
--
-- Fix: sempre comparar a última interaction registrada (do dono do
--   roteiro, para aquele cliente) com o que está na stops jsonb e
--   PREFERIR a interaction quando ela for mais recente que o
--   `visited_at` do stop. A jsonb stops continua sendo a fonte
--   primária; só sobrepomos quando há dado mais novo.
--
-- depends: 015 (interactions), 024 (route_detail enrichment)
-- reversible: yes (re-aplique 024 para reverter)
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
  v_int          RECORD;
  v_done_count   INT := 0;
  v_today        DATE := CURRENT_DATE;
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

    -- Última interação relevante do dono do roteiro para o cliente.
    SELECT i.outcome, i.interaction_type, i.notes,
           i.next_contact_at, i.next_action, i.occurred_at
      INTO v_int
      FROM castor_client_interactions i
     WHERE i.cliente_codigo = v_codigo
       AND i.vendedor_user_id = v_row.user_id
     ORDER BY i.occurred_at DESC
     LIMIT 1;

    -- Quando há interação registrada e ela é MAIS RECENTE que o
    -- visited_at gravado no stop (ou o stop não tem visited_at), a
    -- interaction é a verdade. Isso garante que respostas subsequentes
    -- (mudança de outcome, novo prazo) reflitam imediatamente no kanban.
    IF FOUND AND COALESCE(v_int.outcome,'') <> '' THEN
      v_stop_visited := NULLIF(v_stop->>'visited_at','')::TIMESTAMPTZ;
      IF v_stop_visited IS NULL OR v_int.occurred_at >= v_stop_visited THEN
        v_stop := v_stop
          || jsonb_build_object(
               'outcome',          v_int.outcome,
               'interaction_type', v_int.interaction_type,
               'visited_at',       v_int.occurred_at
             )
          -- next_contact_at: sempre sobrepõe (inclusive limpa quando
          -- terminal zerou no backend).
          || jsonb_build_object(
               'next_contact_at',
               CASE WHEN v_int.next_contact_at IS NOT NULL
                    THEN to_char(v_int.next_contact_at,'YYYY-MM-DD')
                    ELSE NULL END
             )
          || (CASE WHEN v_int.notes IS NOT NULL AND btrim(v_int.notes) <> ''
                    THEN jsonb_build_object('notes', v_int.notes)
                    ELSE '{}'::jsonb END)
          || (CASE WHEN v_int.next_action IS NOT NULL AND btrim(v_int.next_action) <> ''
                    THEN jsonb_build_object('next_action', v_int.next_action)
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
VALUES ('032_route_detail_latest_interaction') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';
