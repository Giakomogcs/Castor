-- file: 031_vendor_orphan_tasks.sql
-- tier: A
-- purpose:
--   A migração 030 criou castor_admin_orphan_tasks (admin-only) para
--   exibir, no kanban, as tarefas avulsas (castor_client_interactions
--   com route_id NULL) atribuídas pelo admin via "Sugestões IA → enviar
--   para vendedor".
--
--   Essas tarefas, porém, também precisam aparecer NO KANBAN DO PRÓPRIO
--   VENDEDOR — caso contrário o vendedor recebe a task pela sidebar de
--   follow-ups mas não vê o card "A fazer/Hoje/Atrasado" no kanban
--   "Meu Roteiro" (que era o que o admin acabou de criar).
--
--   Esta migração adiciona castor_vendor_orphan_tasks(p_caller) que
--   retorna APENAS as tarefas órfãs do próprio caller, no mesmo formato
--   que castor_route_list / castor_route_detail produzem (uma única
--   pseudo-rota com id sintético 'orphan:<vendor_user_id>'). O front
--   chama esta RPC para todos os usuários (admin continua usando a
--   castor_admin_orphan_tasks para ver todos os vendedores).
--
-- depends: 015 (interactions), 030 (admin_orphan_tasks shape), 002 (auth)
-- reversible: yes (DROP FUNCTION)
-- IDEMPOTENTE.

BEGIN;

DROP FUNCTION IF EXISTS castor_vendor_orphan_tasks(UUID);

CREATE OR REPLACE FUNCTION castor_vendor_orphan_tasks(p_caller UUID)
RETURNS JSONB
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
  v_routes    JSONB := '[]'::jsonb;
  v_details   JSONB := '{}'::jsonb;
  v_stops     JSONB;
  v_count     INT;
  v_owner     JSONB;
  v_pseudo_id TEXT;
  v_user_name TEXT;
  v_email     TEXT;
BEGIN
  IF p_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthenticated');
  END IF;

  SELECT COALESCE(u.raw_user_meta_data->>'full_name',
                  u.raw_user_meta_data->>'name',
                  u.email),
         u.email
    INTO v_user_name, v_email
    FROM auth.users u
   WHERE u.id = p_caller;

  -- Monta os stops sintéticos (uma interaction mais recente por cliente).
  SELECT COALESCE(jsonb_agg(stop_obj ORDER BY stop_obj->>'next_contact_at' NULLS LAST), '[]'::jsonb),
         COUNT(*)::INT
    INTO v_stops, v_count
    FROM (
      SELECT jsonb_build_object(
               'cliente_codigo',  t.cliente_codigo,
               'name',            COALESCE(t.cliente_nome, t.cliente_codigo),
               'mun',             t.municipio,
               'uf',              t.uf,
               'a1_mun',          t.municipio,
               'a1_est',          t.uf,
               'outcome',         t.outcome,
               'interaction_type', t.interaction_type,
               'notes',           t.notes,
               'next_contact_at',
                 CASE WHEN t.next_contact_at IS NOT NULL
                      THEN to_char(t.next_contact_at, 'YYYY-MM-DD')
                      ELSE NULL END,
               'next_action',     t.next_action,
               'visited_at',      t.occurred_at,
               '_orphan_task',    true,
               '_interaction_id', t.id
             ) AS stop_obj
        FROM (
          SELECT DISTINCT ON (i2.cliente_codigo)
                 i2.id, i2.cliente_codigo, i2.outcome, i2.interaction_type,
                 i2.notes, i2.next_contact_at, i2.next_action, i2.occurred_at,
                 m.a1_nome AS cliente_nome,
                 m.a1_mun  AS municipio,
                 m.a1_est  AS uf
            FROM castor_client_interactions i2
            LEFT JOIN castor_client_metrics_v2 m ON m.cliente_codigo = i2.cliente_codigo
           WHERE i2.vendedor_user_id = p_caller
             AND i2.route_id IS NULL
             AND (i2.outcome IS NULL
                  OR i2.outcome IN ('voltar_depois','aguardando_resposta','pedido_em_negociacao'))
           ORDER BY i2.cliente_codigo, i2.occurred_at DESC
        ) t
    ) sub;

  IF v_count = 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'data', jsonb_build_object('routes', '[]'::jsonb, 'details', '{}'::jsonb)
    );
  END IF;

  v_pseudo_id := 'orphan:' || p_caller::text;
  v_owner := jsonb_build_object(
    'id',        p_caller,
    'email',     v_email,
    'full_name', v_user_name
  );

  v_routes := jsonb_build_array(jsonb_build_object(
    'id',           v_pseudo_id,
    'name',         '📋 Tarefas avulsas',
    'source',       'vendor_orphan_tasks',
    'status',       'planejado',
    'total_km',     0,
    'stops_count',  v_count,
    'done_count',   0,
    'ai_rationale', NULL,
    'maps_url',     NULL,
    'created_at',   NOW(),
    'updated_at',   NOW(),
    'completed_at', NULL,
    'user_id',      p_caller,
    'user_name',    v_user_name,
    '_orphan',      true
  ));

  v_details := jsonb_build_object(v_pseudo_id, jsonb_build_object(
    'id',          v_pseudo_id,
    'name',        '📋 Tarefas avulsas',
    'status',      'planejado',
    'user_id',     p_caller,
    'owner',       v_owner,
    'stops',       v_stops,
    'stops_count', v_count,
    'done_count',  0,
    '_orphan',     true
  ));

  RETURN jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object('routes', v_routes, 'details', v_details)
  );
END; $$;

GRANT EXECUTE ON FUNCTION castor_vendor_orphan_tasks(UUID) TO authenticated, service_role;

COMMIT;

INSERT INTO castor_schema_migrations(version)
VALUES ('031_vendor_orphan_tasks') ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';
